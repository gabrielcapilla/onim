import std/[algorithm, json, os, strutils, tables]

import ../index/surfaces
import ../index/symbols

type
  SymbolCandidate* = object
    module*: string
    name*: string
    kind*: string
    arity*: int
    signature*: string

  StdlibMap* = ref object
    symbols*: Table[string, seq[SymbolCandidate]]
    modules*: Table[string, bool]
    surface*: SurfaceIndex

const bundledStdlibMap = staticRead("../../../stdlib_map.json")

proc canonicalModule*(module: string): string =
  canonicalSurfaceModule(module)

proc moduleBase*(module: string): string =
  let normalized = canonicalModule(module)
  let slash = normalized.rfind('/')
  if slash >= 0:
    return normalized[slash + 1 .. ^1]
  else:
    return normalized

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

proc addFallback(
    result: var StdlibMap, name, module, kind: string, arity: int, signature = ""
) =
  result.symbols.mgetOrPut(name, @[]).add SymbolCandidate(
    module: module, name: name, kind: kind, arity: arity, signature: signature
  )
  result.modules[canonicalModule(module)] = true

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

  for module in stdlib.modules.keys:
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

proc newStdlibMap(): StdlibMap =
  new(result)
  result.symbols = initTable[string, seq[SymbolCandidate]]()
  result.modules = initTable[string, bool]()

proc emptyStdlibMap*(): StdlibMap =
  result = newStdlibMap()

  result.addFallback("walkDir", "std/os", "iterator", 1)
  result.addFallback("walkDirRec", "std/os", "iterator", 1)
  result.addFallback("Table", "std/tables", "type", 2)
  result.addFallback("initTable", "std/tables", "proc", 0)
  result.addFallback("parseJson", "std/json", "proc", 1)
  result.addFallback("split", "std/strutils", "proc", 2)
  result.addFallback("split", "std/os", "proc", 1)
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
        result.modules[normalized] = true
    if not root.hasKey("symbols") or root["symbols"].kind != JObject:
      return emptyStdlibMap()
    for name in root["symbols"].keys:
      if name.len == 0:
        return emptyStdlibMap()
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
        let candidate = SymbolCandidate(
          module: module,
          name: if exportedName.len > 0: exportedName else: name,
          kind: stringField(entry, "kind"),
          arity: intField(entry, "arity", -1),
          signature: stringField(entry, "signature"),
        )
        var duplicate = false
        for existing in candidates:
          if sameModule(existing.module, candidate.module) and
              existing.signature == candidate.signature:
            duplicate = true
            break
        if not duplicate:
          candidates.add candidate
        result.modules[module] = true
      if candidates.len > 0:
        for candidate in candidates:
          var duplicate = false
          for existing in result.symbols.mgetOrPut(name, @[]):
            if sameModule(existing.module, candidate.module) and
                existing.signature == candidate.signature:
              duplicate = true
              break
          if not duplicate:
            result.symbols.mgetOrPut(name, @[]).add candidate
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
  if not stdlib.symbols.hasKey(name):
    return
  for candidate in stdlib.symbols[name]:
    if qualifier.len > 0 and moduleBase(candidate.module) != qualifier:
      continue
    if arity >= 0 and candidate.arity >= 0 and candidate.arity != arity:
      continue
    result.add candidate
  if result.len == 0 and arity >= 0 and qualifier.len == 0:
    for candidate in stdlib.symbols[name]:
      result.add candidate

proc resolveCandidate*(
    stdlib: StdlibMap, name, qualifier: string, arity = -1
): SymbolCandidate =
  let candidates = stdlib.candidatesFor(name, qualifier, arity)
  if candidates.len == 0:
    return

  let preferredModule =
    case name
    of "walkDir", "walkDirRec": "std/os"
    of "Table", "initTable": "std/tables"
    of "parseJson": "std/json"
    of "split": "std/strutils"
    else: ""
  if preferredModule.len > 0:
    for candidate in candidates:
      if candidate.module == preferredModule:
        return candidate
    if qualifier.len == 0:
      for candidate in stdlib.symbols[name]:
        if candidate.module == preferredModule:
          return candidate

  # split is overloaded throughout the standard library. Prefer the documented
  # canonical import when semantic type/arity information is unavailable.
  for candidate in candidates:
    if candidate.module == "std/strutils":
      return candidate
  if candidates.len == 1:
    return candidates[0]
  var ordered = candidates
  ordered.sort(
    proc(left, right: SymbolCandidate): int =
      cmp(left.module, right.module)
  )
  ordered[0]

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
