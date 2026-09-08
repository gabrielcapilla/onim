import std/[algorithm, json, os, sets, strutils, tables]

import ../index/source_index
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
    documentation*: string
    priority*: CandidatePriority

  StdlibMap* = ref object
    symbols*: Table[string, seq[SymbolCandidate]]
    modules*: HashSet[string]
    surface*: SurfaceIndex
    symbolKeys: Table[string, seq[string]]
    implicitModules: HashSet[string]
    receiverCandidates: Table[string, seq[SymbolCandidate]]
    metadata: StdlibMetadataState

const
  bundledStdlibBinary = staticRead("../../stdlib_map.bin")
  stdlibBinaryMagic = "ONIMBIN1"
  stdlibBinaryVersion = 2'u32
  stdlibBinaryHeaderSize = 32
  maxStdlibBinaryBytes = 64 * 1024 * 1024
  maxStdlibBinaryRecords = 1_000_000

type
  BinaryReader = object
    data: string
    position: int
    valid: bool

  BinarySymbol = object
    name: string
    firstCandidate: uint32
    candidateCount: uint32

  BinaryCandidate = object
    module: string
    name: string
    kind: string
    arity: int32
    signature: string
    documentation: string
    priority: CandidatePriority

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
  result.receiverCandidates = initTable[string, seq[SymbolCandidate]]()

proc rebuildReceiverIndex(stdlib: StdlibMap)

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

proc surfaceIndex*(stdlib: StdlibMap): SurfaceIndex =
  if stdlib == nil:
    return
  if stdlib.surface == nil:
    let origin =
      if stdlib.metadata == metadataComplete: surfaceStdlib else: surfaceFallback
    stdlib.surface = surfaceForMap(stdlib, origin)
  result = stdlib.surface

proc surfaceIsComplete*(stdlib: StdlibMap): bool =
  stdlib != nil and stdlib.metadata == metadataComplete and stdlib.modules.card > 0 and
    stdlib.symbols.len > 0

proc emptyStdlibMap*(): StdlibMap =
  result = newStdlibMap()

proc readByte(reader: var BinaryReader): uint8 =
  if not reader.valid or reader.position < 0 or reader.position >= reader.data.len:
    reader.valid = false
    return
  result = uint8(ord(reader.data[reader.position]))
  inc reader.position

proc readUint32(reader: var BinaryReader): uint32 =
  for shift in 0 .. 3:
    result = result or (uint32(reader.readByte()) shl (shift * 8))

proc readInt32(reader: var BinaryReader): int32 =
  cast[int32](reader.readUint32())

proc readUint64(reader: var BinaryReader): uint64 =
  for shift in 0 .. 7:
    result = result or (uint64(reader.readByte()) shl (shift * 8))

proc ensureBytes(reader: var BinaryReader, count: int): bool =
  if not reader.valid or count < 0 or count > reader.data.len - reader.position:
    reader.valid = false
    return false
  true

proc ensureRecords(reader: var BinaryReader, count, width: int): bool =
  if count < 0 or width < 0 or
      uint64(count) * uint64(width) > uint64(max(reader.data.len - reader.position, 0)):
    reader.valid = false
    return false
  true

proc readCount(reader: var BinaryReader): int =
  let count = reader.readUint32()
  if not reader.valid or count > uint32(maxStdlibBinaryRecords):
    reader.valid = false
    return -1
  int(count)

proc readStringId(reader: var BinaryReader, strings: openArray[string]): string =
  let id = reader.readUint32()
  if not reader.valid or id >= uint32(strings.len):
    reader.valid = false
    return
  strings[int(id)]

proc decodeStdlibBinary(data: string): StdlibMap =
  if data.len < stdlibBinaryHeaderSize:
    return emptyStdlibMap()
  var reader = BinaryReader(data: data, valid: true)
  if reader.data[0 ..< stdlibBinaryMagic.len] != stdlibBinaryMagic:
    return emptyStdlibMap()
  reader.position = stdlibBinaryMagic.len
  let version = reader.readUint32()
  if (version != 1'u32 and version != stdlibBinaryVersion) or reader.readByte() != 1'u8 or
      reader.readByte() != 0'u8 or reader.readByte() != 0'u8 or reader.readByte() != 0'u8:
    return emptyStdlibMap()
  let payloadLength = reader.readUint64()
  let payloadHash = reader.readUint64()
  if not reader.valid or payloadLength > uint64(maxStdlibBinaryBytes) or
      payloadLength != uint64(reader.data.len - reader.position):
    return emptyStdlibMap()
  let payloadStart = reader.position
  let payload =
    if payloadLength == 0:
      ""
    else:
      reader.data[payloadStart ..< payloadStart + int(payloadLength)]
  if contentFingerprint(payload) != payloadHash:
    return emptyStdlibMap()
  reader.data = payload
  reader.position = 0
  if not reader.ensureBytes(6 * sizeof(uint32)):
    return emptyStdlibMap()

  let stringCount = reader.readCount()
  let moduleCount = reader.readCount()
  let symbolCount = reader.readCount()
  let candidateCount = reader.readCount()
  let implicitCount = reader.readCount()
  let blobLengthValue = reader.readUint32()
  let blobLength =
    if reader.valid and blobLengthValue <= uint32(maxStdlibBinaryBytes):
      int(blobLengthValue)
    else:
      -1
  if stringCount < 0 or moduleCount < 0 or symbolCount < 0 or candidateCount < 0 or
      implicitCount < 0 or blobLength < 0 or blobLength > maxStdlibBinaryBytes or
      not reader.ensureRecords(stringCount, 8):
    return emptyStdlibMap()

  var offsets = newSeq[uint32](stringCount)
  var lengths = newSeq[uint32](stringCount)
  for index in 0 ..< stringCount:
    offsets[index] = reader.readUint32()
    lengths[index] = reader.readUint32()
  if not reader.valid or not reader.ensureBytes(blobLength):
    return emptyStdlibMap()
  let blobStart = reader.position
  reader.position += blobLength
  var strings = newSeq[string](stringCount)
  for index in 0 ..< stringCount:
    if uint64(offsets[index]) + uint64(lengths[index]) > uint64(blobLength):
      return emptyStdlibMap()
    if lengths[index] > 0:
      let start = blobStart + int(offsets[index])
      strings[index] = reader.data[start ..< start + int(lengths[index])]

  if not reader.ensureRecords(moduleCount, sizeof(uint32)):
    return emptyStdlibMap()
  result = newStdlibMap()
  var previousModule = ""
  for _ in 0 ..< moduleCount:
    let module = reader.readStringId(strings)
    if not reader.valid or module.len == 0 or canonicalModule(module) != module or
        (previousModule.len > 0 and module <= previousModule):
      return emptyStdlibMap()
    result.modules.incl module
    previousModule = module

  if not reader.ensureRecords(implicitCount, sizeof(uint32)):
    return emptyStdlibMap()
  var previousImplicit = ""
  for _ in 0 ..< implicitCount:
    let module = reader.readStringId(strings)
    if not reader.valid or module.len == 0 or canonicalModule(module) != module or
        (previousImplicit.len > 0 and module <= previousImplicit):
      return emptyStdlibMap()
    result.implicitModules.incl module
    previousImplicit = module
  if result.implicitModules.len == 0:
    return emptyStdlibMap()

  if not reader.ensureRecords(symbolCount, 12):
    return emptyStdlibMap()
  var symbols = newSeq[BinarySymbol](symbolCount)
  var previousName = ""
  var previousCandidate = uint32(0)
  for index in 0 ..< symbolCount:
    let name = reader.readStringId(strings)
    let firstCandidate = reader.readUint32()
    let count = reader.readUint32()
    if not reader.valid or name.len == 0 or
        (previousName.len > 0 and name <= previousName) or
        firstCandidate != previousCandidate or
        uint64(firstCandidate) + uint64(count) > uint64(candidateCount):
      return emptyStdlibMap()
    symbols[index] =
      BinarySymbol(name: name, firstCandidate: firstCandidate, candidateCount: count)
    previousName = name
    previousCandidate = firstCandidate + count
  if previousCandidate != uint32(candidateCount) or
      not reader.ensureRecords(candidateCount, if version == 1'u32: 24 else: 28):
    return emptyStdlibMap()

  var candidates = newSeq[BinaryCandidate](candidateCount)
  for index in 0 ..< candidateCount:
    let module = reader.readStringId(strings)
    let name = reader.readStringId(strings)
    let kind = reader.readStringId(strings)
    let arity = reader.readInt32()
    let signature = reader.readStringId(strings)
    let documentation =
      if version == 1'u32:
        ""
      else:
        reader.readStringId(strings)
    let priority = reader.readByte()
    if reader.readByte() != 0'u8 or reader.readByte() != 0'u8 or
        reader.readByte() != 0'u8 or not reader.valid or module.len == 0 or name.len == 0 or
        kind.len == 0 or module notin result.modules or
        priority > uint8(ord(high(CandidatePriority))):
      return emptyStdlibMap()
    candidates[index] = BinaryCandidate(
      module: module,
      name: name,
      kind: kind,
      arity: arity,
      signature: signature,
      documentation: documentation,
      priority: CandidatePriority(priority),
    )
  if reader.position != reader.data.len:
    return emptyStdlibMap()

  for symbol in symbols:
    result.registerSymbolKey(symbol.name)
    var values: seq[SymbolCandidate] = @[]
    for index in int(symbol.firstCandidate) ..<
        int(symbol.firstCandidate + symbol.candidateCount):
      let candidate = candidates[index]
      if not addUniqueCandidate(
        values,
        SymbolCandidate(
          module: candidate.module,
          name: candidate.name,
          kind: candidate.kind,
          arity: int(candidate.arity),
          signature: candidate.signature,
          documentation: candidate.documentation,
          priority: candidate.priority,
        ),
      ):
        return emptyStdlibMap()
    if values.len == 0:
      return emptyStdlibMap()
    result.symbols[symbol.name] = values
  if result.symbols.len == 0:
    return emptyStdlibMap()
  result.rebuildReceiverIndex()
  result.metadata = metadataComplete
  return result

var cachedBundledMap: StdlibMap

proc loadBundledStdlibMap(): StdlibMap =
  if cachedBundledMap == nil:
    cachedBundledMap = decodeStdlibBinary(bundledStdlibBinary)
  cachedBundledMap

proc loadStdlibBinary*(path: string): StdlibMap =
  if path.len == 0:
    return loadBundledStdlibMap()
  if not fileExists(path):
    return emptyStdlibMap()
  try:
    return decodeStdlibBinary(readFile(path))
  except CatchableError:
    return emptyStdlibMap()

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
  if path.len == 0:
    return loadBundledStdlibMap()
  var content = ""
  if fileExists(path):
    try:
      content = readFile(path)
    except CatchableError:
      discard
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
          documentation: stringField(entry, "description"),
          priority: CandidatePriority(priority),
        )
        discard addUniqueCandidate(candidates, candidate)
        result.modules.incl module
      if candidates.len > 0:
        for candidate in candidates:
          discard addUniqueCandidate(result.symbols.mgetOrPut(name, @[]), candidate)
    if result.symbols.len == 0:
      return emptyStdlibMap()
    result.rebuildReceiverIndex()
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

proc firstParameterType(signature: string): string {.inline.} =
  let open = signature.find('(')
  if open < 0:
    return
  let colon = signature.find(':', open + 1)
  if colon < 0:
    return
  let semicolon = signature.find(';', colon + 1)
  let close = signature.find(')', colon + 1)
  var past = semicolon
  if past < 0 or (close >= 0 and close < past):
    past = close
  if past > colon + 1:
    result = signature[colon + 1 ..< past].strip

proc firstParameterIsFile(signature: string): bool {.inline.} =
  sameIdentifier(signature.firstParameterType, "File")

proc callableCandidate(candidate: SymbolCandidate): bool {.inline.} =
  case candidate.kind
  of "skProc", "skFunc", "skIterator", "skMethod", "skMacro", "skTemplate",
      "skConverter":
    true
  else:
    false

proc receiverIndexKey(module, nominal: string): string {.inline.} =
  let canonical = canonicalModule(module)
  let key = identifierKey(nominal)
  if canonical.len == 0 or key.len == 0:
    return
  canonical & "|" & key

proc rebuildReceiverIndex(stdlib: StdlibMap) =
  stdlib.receiverCandidates.clear()
  for _, candidates in stdlib.symbols:
    for candidate in candidates:
      if not candidate.callableCandidate:
        continue
      let key =
        receiverIndexKey(candidate.module, candidate.signature.firstParameterType)
      if key.len == 0:
        continue
      discard
        addUniqueCandidate(stdlib.receiverCandidates.mgetOrPut(key, @[]), candidate)

proc implicitValueCandidate*(stdlib: StdlibMap, name: string): SymbolCandidate =
  if stdlib == nil or not stdlib.implicitModule("std/system"):
    return
  for candidate in stdlib.candidatesFor(name, "", -1):
    if candidate.kind != "skVar" or not candidate.signature.endsWith("}: File"):
      continue
    if result.module.len > 0:
      return SymbolCandidate()
    result = candidate

proc implicitFileModule(stdlib: StdlibMap, name: string): string =
  let candidate = stdlib.implicitValueCandidate(name)
  if candidate.module.len > 0:
    result = canonicalModule(candidate.module)

proc implicitFileModule(stdlib: StdlibMap): string =
  if stdlib == nil or not stdlib.implicitModule("std/system"):
    return
  for _, candidates in stdlib.symbols:
    for candidate in candidates:
      if candidate.kind != "skVar" or not candidate.signature.endsWith("}: File"):
        continue
      let module = canonicalModule(candidate.module)
      if result.len == 0:
        result = module
      elif result != module:
        return ""

proc fileMembersForModule(
    stdlib: StdlibMap, module, prefix: string
): seq[SymbolCandidate] =
  if module.len == 0:
    return
  let prefixKey = identifierKey(prefix)
  for _, candidates in stdlib.symbols:
    for candidate in candidates:
      if canonicalModule(candidate.module) != module or not candidate.callableCandidate or
          not firstParameterIsFile(candidate.signature):
        continue
      let key = identifierKey(candidate.name)
      if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
        continue
      discard addUniqueCandidate(result, candidate)

proc implicitFileMembers*(
    stdlib: StdlibMap, name, prefix: string
): seq[SymbolCandidate] =
  stdlib.fileMembersForModule(stdlib.implicitFileModule(name), prefix)

proc implicitFileMembers*(stdlib: StdlibMap, prefix: string): seq[SymbolCandidate] =
  stdlib.fileMembersForModule(stdlib.implicitFileModule(), prefix)

proc plainNominalName(value: string): bool {.inline.} =
  if value.len == 0 or not (value[0].isAlphaAscii or value[0] == '_'):
    return false
  for character in value[1 .. ^1]:
    if not (character.isAlphaAscii or character.isDigit or character == '_'):
      return false
  true

proc directNominalReturn*(stdlib: StdlibMap, module, name: string): string =
  if stdlib == nil:
    return
  let canonical = canonicalModule(module)
  if not canonical.startsWith("std/"):
    return
  let candidates = stdlib.candidatesFor(name, moduleBase(canonical), -1)
  if candidates.len != 1 or not candidates[0].callableCandidate or
      canonicalModule(candidates[0].module) != canonical:
    return
  let signature = candidates[0].signature
  let close = signature.rfind(')')
  if close < 0:
    return
  let colon = signature.find(':', close + 1)
  if colon < 0:
    return
  var first = colon + 1
  while first < signature.len and signature[first] in {' ', '\t', '\r', '\n'}:
    inc first
  var past = first
  while past < signature.len and signature[past] notin {' ', '\t', '\r', '\n', '{'}:
    inc past
  let candidate = signature[first ..< past]
  if candidate.plainNominalName:
    result = candidate

proc directNominalMembers*(
    stdlib: StdlibMap, module, nominal, prefix: string
): seq[SymbolCandidate] =
  if stdlib == nil:
    return
  let canonical = canonicalModule(module)
  if not canonical.startsWith("std/") or nominal.len == 0:
    return
  let prefixKey = identifierKey(prefix)
  let receiverKey = receiverIndexKey(canonical, nominal)
  if not stdlib.receiverCandidates.hasKey(receiverKey):
    return
  for candidate in stdlib.receiverCandidates[receiverKey]:
    let key = identifierKey(candidate.name)
    if key.len == 0 or (prefixKey.len > 0 and not key.startsWith(prefixKey)):
      continue
    discard addUniqueCandidate(result, candidate)

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
  let configured = getEnv("ONIM_STDLIB_MAP")
  let cacheKey = if configured.len > 0: configured else: "<bundled>"
  if not hasCachedMap or cacheKey != cachedMapPath:
    cachedMap =
      if configured.len > 0:
        loadStdlibMap(configured)
      else:
        loadStdlibMap("")
    cachedMapPath = cacheKey
    hasCachedMap = true
  cachedMap
