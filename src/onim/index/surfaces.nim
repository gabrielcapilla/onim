import std/[algorithm, strutils, tables]

import ../syntax/lexer
import ../session/ids
import ../session/module_catalog
import ./occurrences
import ./scopes
import ./source_index
import ./symbols

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

proc surfaceKey(name: string): string {.inline.} =
  identifierKey(name)

proc validSurfaceName(name: string): bool {.inline.} =
  surfaceKey(name).len > 0

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

proc moduleUncertain(surface: ModuleSurface): bool {.inline.} =
  surface.uncertainty != {}

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

proc appendBindingsInModule*(
    index: SurfaceIndex, module, prefix: string, destination: var seq[BindingCandidate]
): bool =
  if index == nil or not index.valid or not index.universeComplete:
    return false
  let canonical = canonicalSurfaceModule(module)
  if canonical.len == 0 or not index.byModule.hasKey(canonical):
    return false
  let surface = index.moduleAt(index.byModule[canonical])
  if surface.moduleUncertain:
    return false
  let wanted = surfaceKey(prefix)
  let first = int(surface.firstBinding)
  let past = int(surface.pastBinding)
  if first < 0 or first > past or past > index.bindings.len:
    return false
  for ordinal in first ..< past:
    let binding = index.bindings[ordinal]
    if wanted.len == 0 or binding.key.startsWith(wanted):
      destination.add binding
  true

proc bindingAt*(index: SurfaceIndex, id: BindingId): BindingCandidate =
  if index == nil:
    return
  let ordinal = int(uint32(id)) - 1
  if ordinal >= 0 and ordinal < index.bindings.len:
    return index.bindings[ordinal]

proc exportsFor*(index: SurfaceIndex, binding: BindingCandidate): seq[ExportRecord] =
  if index == nil or binding.firstExport > binding.pastExport or
      binding.pastExport > uint32(index.exports.len):
    return
  for ordinal in int(binding.firstExport) ..< int(binding.pastExport):
    result.add index.exports[ordinal]

proc appendCandidates(
    index: SurfaceIndex, ids: openArray[BindingId], result: var BindingResolution
) =
  for id in ids:
    result.candidates.add index.bindingAt(id)

proc resolution(index: SurfaceIndex, ids: seq[BindingId]): BindingResolution =
  if index == nil or not index.valid:
    result.kind = surfaceUnknown
    return
  if ids.len == 0:
    result.kind = if index.universeComplete: surfaceUnresolved else: surfaceUnknown
    return
  if ids.len > 1:
    result.kind = surfaceAmbiguous
    index.appendCandidates(ids, result)
    return
  let candidate = index.bindingAt(ids[0])
  let surface = index.moduleAt(candidate.surface)
  index.appendCandidates(ids, result)
  if not index.universeComplete or surface.moduleUncertain:
    result.kind = surfaceUnknown
  else:
    result.kind = surfaceResolved

proc lookup*(index: SurfaceIndex, name: string): BindingResolution =
  let key = surfaceKey(name)
  if key.len == 0 or index == nil or not index.byName.hasKey(key):
    return index.resolution(@[])
  index.resolution(index.byName[key])

proc lookupInModule*(index: SurfaceIndex, module, name: string): BindingResolution =
  if index == nil:
    result.kind = surfaceUnknown
    return
  let canonical = canonicalSurfaceModule(module)
  if canonical.len == 0 or not index.byModule.hasKey(canonical):
    return index.resolution(@[])
  let surface = index.byModule[canonical]
  let moduleInfo = index.moduleAt(surface)
  let wanted = surfaceKey(name)
  var ids: seq[BindingId] = @[]
  for ordinal in int(moduleInfo.firstBinding) ..< int(moduleInfo.pastBinding):
    let binding = index.bindings[ordinal]
    if binding.key == wanted:
      ids.add BindingId(uint32(ordinal + 1))
  index.resolution(ids)

proc resolveSurfaceReference*(
    index: SurfaceIndex, catalog: ModuleCatalog, name, qualifier, owner: string
): BindingResolution =
  if index == nil:
    result.kind = surfaceUnknown
    return
  if qualifier.len == 0:
    return index.lookup(name)

  if catalog != nil:
    let module = catalog.resolveModuleName(owner, qualifier)
    case module.kind
    of moduleResolved:
      return index.lookupInModule(module.module, name)
    of moduleAmbiguous, moduleUnknown:
      result.kind = surfaceUnknown
    of moduleMissing:
      result.kind = surfaceUnresolved
    return

  let module = index.moduleForReference(qualifier, owner)
  if module.len == 0:
    result.kind = if index.universeIsComplete: surfaceUnresolved else: surfaceUnknown
    return
  index.lookupInModule(module, name)

proc moduleForResolution*(index: SurfaceIndex, resolution: BindingResolution): string =
  if index == nil or resolution.kind != surfaceResolved or resolution.candidates.len != 1:
    return
  index.moduleAt(resolution.candidates[0].surface).module

proc addSourceUncertainty(
    target: var set[SurfaceUncertainty], reason: ScopeUncertainty
) =
  case reason
  of scopeNestedBlock:
    discard
  of scopeConditional:
    target.incl surfaceConditional
  of scopeInclude:
    target.incl surfaceInclude
  of scopeGenerated:
    target.incl surfaceGenerated
  of scopeMalformed:
    target.incl surfaceMalformed
  else:
    target.incl surfaceUnsupported

proc addOccurrenceUncertainty(
    target: var set[SurfaceUncertainty], reason: OccurrenceUncertainty
) =
  case reason
  of uncertaintyNestedScope, uncertaintyDeclarationOrder:
    discard
  of uncertaintyConditional:
    target.incl surfaceConditional
  of uncertaintyInclude:
    target.incl surfaceInclude
  of uncertaintyGenerated:
    target.incl surfaceGenerated
  of uncertaintyMalformed:
    target.incl surfaceMalformed
  else:
    target.incl surfaceUnsupported

proc projectSurfaceInput*(
    module: string, index: SourceIndex, origin = surfaceProject
): SurfaceInput =
  result.module = module
  result.origin = origin
  if index == nil:
    result.uncertainty = {surfaceUnsupported, surfaceUniverseIncomplete}
    return
  for reason in index.scopes.uncertainty:
    result.uncertainty.addSourceUncertainty(reason)
  for reason in index.occurrences.uncertainty:
    result.uncertainty.addOccurrenceUncertainty(reason)
  if index.includes.len > 0:
    result.uncertainty.incl surfaceInclude
  if index.hasUnresolvedExports:
    result.uncertainty.incl surfaceReexport
  for symbol in index.symbols:
    if not symbol.exported or symbol.nameToken >= uint32(index.parsed.tokens.len):
      continue
    let token = index.parsed.tokens[int(symbol.nameToken)]
    if token.kind != tkIdentifier or index.parsed.tokens.tokenTextLen(token) == 0:
      result.uncertainty.incl surfaceMalformed
      continue
    result.exports.add SurfaceExportInput(
      name: index.parsed.tokens.tokenText(token),
      kind: symbol.kind,
      kindKnown: true,
      declaredArity: -1,
      shapeKnown: false,
      nameToken: symbol.nameToken,
    )

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
