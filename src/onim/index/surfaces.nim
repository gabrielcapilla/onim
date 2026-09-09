import std/[algorithm, strutils, tables]

import ../session/ids
import ../session/module_catalog
import ./symbols
import ./surface_names

type
  SurfaceId* = distinct uint32
  BindingId* = distinct uint32

  SurfaceOrigin* = enum
    surfaceProject
    surfaceStdlib
    surfaceExternal
    surfaceFallback

  SurfaceUncertainty* = enum
    surfaceConditional
    surfaceInclude
    surfaceReexport
    surfaceGenerated
    surfaceUnsupported
    surfaceMalformed
    surfaceToolchainMismatch
    surfaceUniverseIncomplete

  SurfaceExportInput* = object
    name*: string
    kind*: SourceSymbolKind
    kindKnown*: bool
    declaredArity*: int32
    signature*: string
    shapeKnown*: bool
    nameToken*: uint32

  SurfaceInput* = object
    module*: string
    origin*: SurfaceOrigin
    uncertainty*: set[SurfaceUncertainty]
    exports*: seq[SurfaceExportInput]

  SurfaceContributor* = object
    fileId*: FileId
    contentGeneration*: ContentGeneration
    input*: SurfaceInput

  ExportRecord* = object
    kind*: SourceSymbolKind
    declaredArity*: int32
    signature*: string
    shapeKnown*: bool
    nameToken*: uint32

  BindingCandidate* = object
    surface*: SurfaceId
    name*: string
    key*: string
    firstExport*: uint32
    pastExport*: uint32

  ModuleSurface* = object
    module*: string
    origin*: SurfaceOrigin
    firstBinding*: uint32
    pastBinding*: uint32
    uncertainty*: set[SurfaceUncertainty]

  SurfaceResolutionKind* = enum
    surfaceUnknown
    surfaceUnresolved
    surfaceAmbiguous
    surfaceResolved

  BindingResolution* = object
    kind*: SurfaceResolutionKind
    candidates*: seq[BindingCandidate]

type
  SurfaceContributorIdentity = object
    fileId: FileId
    contentGeneration: ContentGeneration

  SurfaceBindingRecord = object
    name: string
    key: string
    firstExport: uint32
    pastExport: uint32

  SurfaceModuleRecord = ref object
    module: string
    origin: SurfaceOrigin
    uncertainty: set[SurfaceUncertainty]
    contributors: seq[SurfaceContributorIdentity]
    bindings: seq[SurfaceBindingRecord]
    exports: seq[ExportRecord]

  SurfaceAccumulator = object
    module: string
    origin: SurfaceOrigin
    uncertainty: set[SurfaceUncertainty]
    contributors: seq[SurfaceContributorIdentity]
    exports: seq[SurfaceExportInput]

  SurfaceIndex* = ref object
    modules: seq[ModuleSurface]
    bindings: seq[BindingCandidate]
    exports: seq[ExportRecord]
    records: seq[SurfaceModuleRecord]
    byName: Table[string, seq[BindingId]]
    byModule: Table[string, SurfaceId]
    valid: bool
    universeComplete: bool

const invalidSurfaceToken = high(uint32)

proc `==`*(left, right: SurfaceId): bool {.borrow.}
proc `==`*(left, right: BindingId): bool {.borrow.}

proc canonicalSurfaceModule*(module: string): string =
  canonicalModuleName(module)

proc sameExport(left, right: SurfaceExportInput): bool {.inline.} =
  surfaceKey(left.name) == surfaceKey(right.name) and left.kind == right.kind and
    left.declaredArity == right.declaredArity and left.signature == right.signature

proc compareExports(left, right: SurfaceExportInput): int =
  let leftKey = surfaceKey(left.name)
  let rightKey = surfaceKey(right.name)
  result = cmp(leftKey, rightKey)
  if result != 0:
    return
  result = cmp(left.name, right.name)
  if result != 0:
    return
  result = cmp(ord(left.kind), ord(right.kind))
  if result != 0:
    return
  result = cmp(left.declaredArity, right.declaredArity)
  if result != 0:
    return
  result = cmp(left.signature, right.signature)
  if result != 0:
    return
  result = cmp(left.nameToken, right.nameToken)

proc addUncertainty(
    target: var set[SurfaceUncertainty], source: set[SurfaceUncertainty]
) {.inline.} =
  for reason in source:
    target.incl reason

proc findOrAdd(
    accumulators: var seq[SurfaceAccumulator],
    byModule: var Table[string, int],
    input: SurfaceInput,
): int =
  let module = canonicalSurfaceModule(input.module)
  if module.len == 0:
    return -1
  if byModule.hasKey(module):
    result = byModule[module]
    accumulators[result].uncertainty.addUncertainty(input.uncertainty)
    if accumulators[result].origin != input.origin:
      accumulators[result].uncertainty.incl surfaceUnsupported
    return
  result = accumulators.len
  byModule[module] = result
  accumulators.add SurfaceAccumulator(
    module: module, origin: input.origin, uncertainty: input.uncertainty
  )

proc validExportInput(exported: SurfaceExportInput): bool =
  exported.kindKnown and validSurfaceName(exported.name)

proc sameContributorSequence(left, right: openArray[SurfaceContributorIdentity]): bool =
  if left.len != right.len:
    return false
  for index in 0 ..< left.len:
    if uint32(left[index].fileId) != uint32(right[index].fileId) or
        left[index].contentGeneration.value != right[index].contentGeneration.value:
      return false
  true

proc buildSurfaceModuleRecord(accumulator: SurfaceAccumulator): SurfaceModuleRecord =
  new(result)
  result.module = accumulator.module
  result.origin = accumulator.origin
  result.uncertainty = accumulator.uncertainty
  result.contributors = accumulator.contributors

  var exports = accumulator.exports
  exports.sort(compareExports)
  var cursor = 0
  while cursor < exports.len:
    let firstExport = uint32(result.exports.len)
    let key = surfaceKey(exports[cursor].name)
    let name = exports[cursor].name
    while cursor < exports.len and surfaceKey(exports[cursor].name) == key:
      let exported = exports[cursor]
      result.exports.add ExportRecord(
        kind: exported.kind,
        declaredArity: exported.declaredArity,
        signature: exported.signature,
        shapeKnown: exported.shapeKnown,
        nameToken: exported.nameToken,
      )
      inc cursor
    result.bindings.add SurfaceBindingRecord(
      name: name,
      key: key,
      firstExport: firstExport,
      pastExport: uint32(result.exports.len),
    )

proc materializeSurfaceIndex(
    records: seq[SurfaceModuleRecord], universeComplete: bool
): SurfaceIndex =
  new(result)
  result.valid = true
  result.universeComplete = universeComplete
  for record in records:
    if record != nil and record.uncertainty != {}:
      result.universeComplete = false
  result.records = records
  for record in records:
    let surface = SurfaceId(uint32(result.modules.len + 1))
    let firstBinding = uint32(result.bindings.len)
    let firstExport = uint32(result.exports.len)
    for exported in record.exports:
      result.exports.add exported
    for binding in record.bindings:
      result.bindings.add BindingCandidate(
        surface: surface,
        name: binding.name,
        key: binding.key,
        firstExport: firstExport + binding.firstExport,
        pastExport: firstExport + binding.pastExport,
      )
      result.byName.mgetOrPut(binding.key, @[]).add(
        BindingId(uint32(result.bindings.len))
      )
    result.modules.add ModuleSurface(
      module: record.module,
      origin: record.origin,
      firstBinding: firstBinding,
      pastBinding: uint32(result.bindings.len),
      uncertainty:
        if result.universeComplete:
          record.uncertainty
        else:
          record.uncertainty + {surfaceUniverseIncomplete},
    )
    result.byModule[record.module] = surface

proc addSurfaceInput(
    accumulators: var seq[SurfaceAccumulator],
    byModule: var Table[string, int],
    input: SurfaceInput,
    contributor: SurfaceContributorIdentity,
): bool =
  let accumulator = findOrAdd(accumulators, byModule, input)
  if accumulator < 0:
    return false
  if contributor.fileId.valid:
    accumulators[accumulator].contributors.add contributor
  result = true
  for exported in input.exports:
    if not validExportInput(exported):
      result = false
      continue
    for existing in accumulators[accumulator].exports:
      if sameExport(existing, exported) and existing.nameToken == invalidSurfaceToken and
          exported.nameToken == invalidSurfaceToken:
        result = false
    accumulators[accumulator].exports.add exported

proc buildSurfaceIndex*(
    inputs: openArray[SurfaceInput], universeComplete = true
): SurfaceIndex =
  new(result)
  result.valid = true
  result.universeComplete = universeComplete
  var accumulators: seq[SurfaceAccumulator] = @[]
  var byModule = initTable[string, int]()

  for input in inputs:
    if not addSurfaceInput(accumulators, byModule, input, SurfaceContributorIdentity()):
      result.valid = false

  if not result.valid:
    result.universeComplete = false
    return

  accumulators.sort(
    proc(left, right: SurfaceAccumulator): int =
      cmp(left.module, right.module)
  )
  var records = newSeqOfCap[SurfaceModuleRecord](accumulators.len)
  for accumulator in accumulators:
    records.add buildSurfaceModuleRecord(accumulator)
    if accumulator.uncertainty != {}:
      result.universeComplete = false
  result = materializeSurfaceIndex(records, result.universeComplete)

proc buildProjectSurfaceIndex*(
    contributors: openArray[SurfaceContributor],
    universeComplete = true,
    previous: SurfaceIndex = nil,
): SurfaceIndex =
  var accumulators: seq[SurfaceAccumulator] = @[]
  var byModule = initTable[string, int]()
  var valid = true
  for contributor in contributors:
    let identity = SurfaceContributorIdentity(
      fileId: contributor.fileId, contentGeneration: contributor.contentGeneration
    )
    if not addSurfaceInput(accumulators, byModule, contributor.input, identity):
      valid = false
  if not valid:
    new(result)
    result.valid = false
    result.universeComplete = false
    return

  accumulators.sort(
    proc(left, right: SurfaceAccumulator): int =
      cmp(left.module, right.module)
  )
  var records = newSeqOfCap[SurfaceModuleRecord](accumulators.len)
  for accumulator in accumulators:
    var record: SurfaceModuleRecord
    if previous != nil and previous.valid and
        previous.byModule.hasKey(accumulator.module):
      let surface = previous.byModule[accumulator.module]
      let ordinal = int(uint32(surface)) - 1
      if ordinal >= 0 and ordinal < previous.records.len:
        let candidate = previous.records[ordinal]
        if candidate != nil and candidate.module == accumulator.module and
            candidate.origin == accumulator.origin and
            candidate.uncertainty == accumulator.uncertainty and
            sameContributorSequence(candidate.contributors, accumulator.contributors):
          record = candidate
    if record == nil:
      record = buildSurfaceModuleRecord(accumulator)
    records.add record

  result = materializeSurfaceIndex(records, universeComplete)

proc valid*(index: SurfaceIndex): bool =
  index != nil and index.valid

proc universeIsComplete*(index: SurfaceIndex): bool =
  index != nil and index.valid and index.universeComplete

proc moduleKnown*(index: SurfaceIndex, module: string): bool =
  index != nil and index.valid and index.byModule.hasKey(canonicalSurfaceModule(module))

proc moduleForReference*(
    index: SurfaceIndex, reference: string, owner: string = ""
): string =
  if index == nil or not index.valid:
    return
  let target = canonicalSurfaceModule(reference)
  if target.len == 0:
    return
  if index.byModule.hasKey(target):
    return target
  let current = canonicalSurfaceModule(owner)
  let slash = current.rfind('/')
  if slash < 0:
    return
  let relative = current[0 ..< slash] & "/" & target
  if index.byModule.hasKey(relative):
    return relative

proc moduleCount*(index: SurfaceIndex): int =
  if index != nil:
    return index.modules.len

proc bindingCount*(index: SurfaceIndex): int =
  if index != nil:
    return index.bindings.len

proc exportCount*(index: SurfaceIndex): int =
  if index != nil:
    return index.exports.len

proc moduleAt*(index: SurfaceIndex, id: SurfaceId): ModuleSurface =
  if index == nil:
    return
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < index.modules.len:
    return index.modules[ordinal]

proc surfaceIdForModule*(index: SurfaceIndex, module: string): SurfaceId =
  if index == nil or not index.valid:
    return
  let canonical = canonicalSurfaceModule(module)
  if canonical.len > 0 and index.byModule.hasKey(canonical):
    return index.byModule[canonical]

proc bindingAt*(index: SurfaceIndex, id: BindingId): BindingCandidate =
  if index == nil:
    return
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < index.bindings.len:
    return index.bindings[ordinal]

proc bindingIdsForName*(index: SurfaceIndex, key: string): seq[BindingId] =
  if index != nil and index.valid and index.byName.hasKey(key):
    return index.byName[key]

proc exportAt*(index: SurfaceIndex, ordinal: uint32): ExportRecord =
  let position = int(ordinal)
  if index != nil and position >= 0 and position < index.exports.len:
    return index.exports[position]

proc validateSurfaceIndex*(index: SurfaceIndex): bool =
  if index == nil or not index.valid:
    return false
  var previousModule = ""
  var previousBinding = 0'u32
  for moduleIndex, module in index.modules:
    if module.module.len == 0 or (moduleIndex > 0 and module.module <= previousModule) or
        module.firstBinding > module.pastBinding or
        module.pastBinding > uint32(index.bindings.len):
      return false
    previousModule = module.module
    var lastKey = ""
    for bindingOrdinal in int(module.firstBinding) ..< int(module.pastBinding):
      let binding = index.bindings[bindingOrdinal]
      if binding.surface != SurfaceId(uint32(moduleIndex + 1)) or
          binding.firstExport >= binding.pastExport or
          binding.pastExport > uint32(index.exports.len) or
          (previousBinding > 0 and uint32(bindingOrdinal + 1) <= previousBinding) or
          (lastKey.len > 0 and binding.key <= lastKey):
        return false
      previousBinding = uint32(bindingOrdinal + 1)
      lastKey = binding.key
      if not index.byName.hasKey(binding.key):
        return false
      for exportOrdinal in int(binding.firstExport) ..< int(binding.pastExport):
        discard index.exports[exportOrdinal]
  for key, ids in index.byName:
    var previousModuleForName = ""
    for id in ids:
      let binding = index.bindingAt(id)
      if binding.key != key or binding.surface == SurfaceId(0):
        return false
      let module = index.moduleAt(binding.surface).module
      if previousModuleForName.len > 0 and module <= previousModuleForName:
        return false
      previousModuleForName = module
  true
