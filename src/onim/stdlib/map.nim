import std/[json, os, sets, strutils, tables]

import ../index/source_index
import ../index/surfaces
import ../index/symbols
import ../syntax/imports
import ../syntax/module_names
import ../syntax/tokens
import ./doc_normalize
import ./map_binary_reader
import ./map_decode
import ./receiver_helpers

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
    receiverCandidates*: Table[string, seq[SymbolCandidate]]
    metadata: StdlibMetadataState

const
  bundledStdlibBinary = staticRead("../../stdlib_map.bin")
  stdlibBinaryMagic = "ONIMBIN1"
  stdlibBinaryVersion = 2'u32
  stdlibBinaryHeaderSize = 32
  maxStdlibBinaryBytes = 64 * 1024 * 1024
  maxStdlibBinaryRecords = 1_000_000

type
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

proc addUniqueCandidate*(
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

  let stringCount = reader.readCount(maxStdlibBinaryRecords)
  let moduleCount = reader.readCount(maxStdlibBinaryRecords)
  let symbolCount = reader.readCount(maxStdlibBinaryRecords)
  let candidateCount = reader.readCount(maxStdlibBinaryRecords)
  let implicitCount = reader.readCount(maxStdlibBinaryRecords)
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
        normalizeDocumentation(reader.readStringId(strings))
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
          documentation: normalizeDocumentation(stringField(entry, "description")),
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

proc rebuildReceiverIndex(stdlib: StdlibMap) =
  stdlib.receiverCandidates.clear()
  for _, candidates in stdlib.symbols:
    for candidate in candidates:
      if not callableCandidate(candidate.kind):
        continue
      let key =
        receiverIndexKey(candidate.module, firstParameterType(candidate.signature))
      if key.len == 0:
        continue
      discard
        addUniqueCandidate(stdlib.receiverCandidates.mgetOrPut(key, @[]), candidate)
