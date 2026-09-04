import std/[algorithm, json, os, sets, strutils, tables]

import ../index/surfaces
import ../index/symbols
import ../syntax/imports

type
  CandidatePriority* = enum
    candidateDefault
    candidateCanonical

  CandidateResolutionState* = enum
    candidateResolutionMissing
    candidateResolutionResolved
    candidateResolutionAmbiguous

  StdlibMetadataState = enum
    metadataMissing
    metadataComplete

  SymbolCandidate* = object
    module*: string
    name*: string
    kind*: string
    arity*: int
    signature*: string
    priority*: CandidatePriority

  StdlibMap* = ref object
    symbols*: Table[string, seq[SymbolCandidate]]
    modules*: HashSet[string]
    surface*: SurfaceIndex
    symbolKeys: Table[string, seq[string]]
    implicitModules: HashSet[string]
    metadata: StdlibMetadataState

const bundledStdlibMap = staticRead("../../../stdlib_map.json")

proc canonicalModule*(module: string): string =
  canonicalSurfaceModule(module)

proc moduleBase*(module: string): string =
  moduleLeaf(module)

proc sameModule*(left, right: string): bool =
  let a = canonicalModule(left)
  let b = canonicalModule(right)
  if a == b:
    return true
  if a.startsWith("std/") and b == a[4 .. ^1]:
    return true
  if b.startsWith("std/") and a == b[4 .. ^1]:
    return true
  return false

proc sourceSymbolKind(kind: string, kindKnown: var bool): SourceSymbolKind =
  kindKnown = true
  case kind
  of "skProc", "proc":
    symbolProc
  of "skFunc", "func":
    symbolFunc
  of "skIterator", "iterator":
    symbolIterator
  of "skMethod", "method":
    symbolMethod
  of "skMacro", "macro":
    symbolMacro
  of "skTemplate", "template":
    symbolTemplate
  of "skConverter", "converter":
    symbolConverter
  of "skType", "type":
    symbolType
  of "skVar", "var":
    symbolVar
  of "skLet", "let":
    symbolLet
  of "skConst", "const":
    symbolConst
  else:
    kindKnown = false
    symbolProc

proc surfaceForMap(stdlib: StdlibMap, origin: SurfaceOrigin): SurfaceIndex =
  var inputs: seq[SurfaceInput] = @[]
  var inputByModule = initTable[string, int]()

  for module in stdlib.modules:
    let normalized = canonicalModule(module)
    if normalized.len == 0 or inputByModule.hasKey(normalized):
      continue
    inputByModule[normalized] = inputs.len
    inputs.add SurfaceInput(module: normalized, origin: origin, exports: @[])

  for name, candidates in stdlib.symbols:
    for candidate in candidates:
      let module = canonicalModule(candidate.module)
      if module.len == 0:
        continue
      var inputIndex: int
      if inputByModule.hasKey(module):
        inputIndex = inputByModule[module]
      else:
        inputIndex = inputs.len
        inputByModule[module] = inputIndex
        inputs.add SurfaceInput(module: module, origin: origin, exports: @[])
      var kindKnown = false
      let kind = sourceSymbolKind(candidate.kind, kindKnown)
      var input = inputs[inputIndex]
      input.exports.add SurfaceExportInput(
        name: if candidate.name.len > 0: candidate.name else: name,
        kind: kind,
        kindKnown: kindKnown,
        declaredArity: int32(candidate.arity),
        signature: candidate.signature,
        shapeKnown: candidate.arity >= 0 or candidate.signature.len > 0,
        nameToken: high(uint32),
      )
      inputs[inputIndex] = input

  let complete = origin == surfaceStdlib
  if not complete:
    for input in inputs.mitems:
      input.uncertainty.incl surfaceUniverseIncomplete
  buildSurfaceIndex(inputs, complete)

proc addUniqueCandidate(
    candidates: var seq[SymbolCandidate], candidate: SymbolCandidate
): bool =
  for existing in candidates:
    if sameModule(existing.module, candidate.module) and
        existing.signature == candidate.signature:
      return false
  candidates.add candidate
  true

proc newStdlibMap(): StdlibMap =
  new(result)
  result.symbols = initTable[string, seq[SymbolCandidate]]()
  result.modules = initHashSet[string]()
  result.symbolKeys = initTable[string, seq[string]]()
  result.implicitModules = initHashSet[string]()

proc registerSymbolKey(stdlib: StdlibMap, name: string) =
  let key = identifierKey(name)
  if key.len == 0:
    return
  if not stdlib.symbolKeys.hasKey(key):
    stdlib.symbolKeys[key] = @[]
  for existing in stdlib.symbolKeys[key]:
    if existing == name:
      return
  stdlib.symbolKeys[key].add name

proc surfaceIsComplete*(stdlib: StdlibMap): bool =
  stdlib != nil and stdlib.surface != nil and stdlib.surface.valid() and
    stdlib.surface.universeIsComplete() and stdlib.metadata == metadataComplete

proc emptyStdlibMap*(): StdlibMap =
  result = newStdlibMap()
  result.surface = surfaceForMap(result, surfaceFallback)

proc intField(node: JsonNode, name: string, fallback: int): int =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JInt:
    return node[name].getInt
  fallback

proc stringField(node: JsonNode, name: string): string =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JString:
    return node[name].getStr
  ""

proc loadStdlibMap*(path: string): StdlibMap =
  var content = ""
  if path.len > 0 and fileExists(path):
    try:
      content = readFile(path)
    except CatchableError:
      discard
  if content.len == 0:
    content = bundledStdlibMap
  if content.len == 0:
    return emptyStdlibMap()
  try:
    result = newStdlibMap()
    let root = parseJson(content)
    if root.kind != JObject:
      return emptyStdlibMap()
    if root.hasKey("modules"):
      if root["modules"].kind != JObject:
        return emptyStdlibMap()
      for module in root["modules"].keys:
        let normalized = canonicalModule(module)
        if normalized.len == 0:
          return emptyStdlibMap()
        result.modules.incl normalized
    if not root.hasKey("implicitModules") or root["implicitModules"].kind != JArray:
      return emptyStdlibMap()
    for entry in root["implicitModules"].items:
      if entry.kind != JString:
        return emptyStdlibMap()
      let module = canonicalModule(entry.getStr)
      if module.len == 0:
        return emptyStdlibMap()
      result.implicitModules.incl module
    if result.implicitModules.len == 0:
      return emptyStdlibMap()
    result.metadata = metadataComplete
    if not root.hasKey("symbols") or root["symbols"].kind != JObject:
      return emptyStdlibMap()
    for name in root["symbols"].keys:
      if name.len == 0:
        return emptyStdlibMap()
      result.registerSymbolKey(name)
      let entries = root["symbols"][name]
      if entries.kind != JArray:
        return emptyStdlibMap()
      var candidates: seq[SymbolCandidate] = @[]
      for entry in entries.items:
        if entry.kind != JObject:
          return emptyStdlibMap()
        let module = canonicalModule(stringField(entry, "module"))
        if module.len == 0 or stringField(entry, "kind").len == 0:
          return emptyStdlibMap()
        let exportedName = stringField(entry, "name")
        let priority = intField(entry, "priority", 0)
        if priority < 0 or priority > ord(high(CandidatePriority)):
          return emptyStdlibMap()
        let candidate = SymbolCandidate(
          module: module,
          name: if exportedName.len > 0: exportedName else: name,
          kind: stringField(entry, "kind"),
          arity: intField(entry, "arity", -1),
          signature: stringField(entry, "signature"),
          priority: CandidatePriority(priority),
        )
        discard addUniqueCandidate(candidates, candidate)
        result.modules.incl module
      if candidates.len > 0:
        for candidate in candidates:
          discard addUniqueCandidate(result.symbols.mgetOrPut(name, @[]), candidate)
    if result.symbols.len == 0:
      return emptyStdlibMap()
    result.surface = surfaceForMap(result, surfaceStdlib)
    if result.surface == nil or not result.surface.valid():
      return emptyStdlibMap()
  except CatchableError:
    return emptyStdlibMap()

proc candidatesFor*(
    stdlib: StdlibMap, name, qualifier: string, arity = -1
): seq[SymbolCandidate] =
  if stdlib == nil:
    return
  var names: seq[string] = @[]
  let key = identifierKey(name)
  if stdlib.symbolKeys.hasKey(key):
    names = stdlib.symbolKeys[key]
  elif stdlib.symbols.hasKey(name):
    names.add name
  for symbolName in names:
    for candidate in stdlib.symbols[symbolName]:
      if qualifier.len > 0 and
          not sameIdentifier(moduleBase(candidate.module), qualifier):
        continue
      if arity >= 0 and candidate.arity >= 0 and candidate.arity != arity:
        continue
      result.add candidate
  if result.len == 0 and arity >= 0:
    for symbolName in names:
      for candidate in stdlib.symbols[symbolName]:
        if qualifier.len > 0 and
            not sameIdentifier(moduleBase(candidate.module), qualifier):
          continue
        result.add candidate

proc implicitModule*(stdlib: StdlibMap, module: string): bool =
  stdlib != nil and canonicalModule(module) in stdlib.implicitModules

proc resolveUniqueCandidate*(
  stdlib: StdlibMap, name, qualifier: string, arity = -1
): tuple[state: CandidateResolutionState, candidate: SymbolCandidate]

proc resolveCandidate*(
    stdlib: StdlibMap, name, qualifier: string, arity = -1
): SymbolCandidate =
  let candidates = stdlib.candidatesFor(name, qualifier, arity)
  if candidates.len == 0:
    return
  let unique = stdlib.resolveUniqueCandidate(name, qualifier, arity)
  if unique.state == candidateResolutionResolved:
    return unique.candidate
  var ordered = candidates
  ordered.sort(
    proc(left, right: SymbolCandidate): int =
      cmp(left.module, right.module)
  )
  ordered[0]

proc resolveUniqueCandidate*(
    stdlib: StdlibMap, name, qualifier: string, arity = -1
): tuple[state: CandidateResolutionState, candidate: SymbolCandidate] =
  ## Resolve only when the map gives one safe module identity. The legacy
  ## `resolveCandidate` API remains available for callers that explicitly
  ## accept its deterministic fallback; semantic features use this stricter
  ## result so a collision cannot become an unsafe edit or diagnostic.
  let candidates = stdlib.candidatesFor(name, qualifier, arity)
  if candidates.len == 0:
    return

  if qualifier.len == 0:
    var canonicalModuleName = ""
    var canonicalFound = false
    var canonicalCandidate: SymbolCandidate
    for candidate in stdlib.candidatesFor(name, "", -1):
      if candidate.priority != candidateCanonical:
        continue
      let module = canonicalModule(candidate.module)
      if not canonicalFound:
        canonicalModuleName = module
        canonicalCandidate = candidate
        canonicalFound = true
      elif module != canonicalModuleName:
        return (candidateResolutionAmbiguous, SymbolCandidate())
    if canonicalFound:
      return (candidateResolutionResolved, canonicalCandidate)

  if candidates.len == 1:
    return (candidateResolutionResolved, candidates[0])

  let firstModule = canonicalModule(candidates[0].module)
  var sameModule = true
  for candidate in candidates[1 .. ^1]:
    if canonicalModule(candidate.module) != firstModule:
      sameModule = false
      break
  if sameModule:
    return (candidateResolutionResolved, candidates[0])

  result.state = candidateResolutionAmbiguous

proc findStdlibMap*(): string =
  let configured = getEnv("ONIM_STDLIB_MAP")
  if configured.len > 0 and fileExists(configured):
    return configured
  let candidates = [
    getAppDir() / "stdlib_map.json",
    getCurrentDir() / "stdlib_map.json",
    getAppDir() / ".." / "share" / "onim" / "stdlib_map.json",
  ]
  for candidate in candidates:
    if fileExists(candidate):
      return candidate
  ""

var cachedMap: StdlibMap
var cachedMapPath = ""
var hasCachedMap = false

proc stdlibMap*(): StdlibMap =
  let path = findStdlibMap()
  if not hasCachedMap or path != cachedMapPath:
    cachedMap = loadStdlibMap(path)
    cachedMapPath = path
    hasCachedMap = true
  cachedMap
