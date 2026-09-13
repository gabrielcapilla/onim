import ../index/source_index
import ../index/type_local_models
import ../session/ids
import ./ufcs_arity

type
  DefinitionResolutionKind* = enum
    definitionUnknown
    definitionUnresolved
    definitionAmbiguous
    definitionUnsupported
    definitionResolved

  DefinitionTargetKind* = enum
    targetDeclaration
    targetObjectField

  ObjectFieldSource* = enum
    objectFieldsNominal
    objectFieldsLocalTuple

  DefinitionTarget* = object
    kind*: DefinitionTargetKind
    snapshotId*: SnapshotId
    fileId*: FileId
    contentGeneration*: ContentGeneration
    nameToken*: uint32

  DefinitionResolution* = object
    kind*: DefinitionResolutionKind
    target*: DefinitionTarget

  ObjectReceiverResolution* = object
    resolved*: bool
    typeTarget*: DefinitionTarget
    provider*: SourceIndex
    objectOrdinal*: uint32
    exportedOnly*: bool
    fieldSource*: ObjectFieldSource

  LocalTypeResolution* = object
    info*: LocalTypeInfo
    snapshotId*: SnapshotId
    fileId*: FileId
    contentGeneration*: ContentGeneration

proc sameDefinitionTarget*(left, right: DefinitionTarget): bool {.inline.} =
  left.kind == right.kind and left.snapshotId.value == right.snapshotId.value and
    left.fileId.value == right.fileId.value and
    left.contentGeneration.value == right.contentGeneration.value and
    left.nameToken == right.nameToken

type UfcsTargetRecord* = object
  target*: DefinitionTarget
  arityKind*: UfcsFormalArityKind
  arity*: uint32
  requiredArity*: uint32

proc addUfcsTarget*(
    targets: var seq[UfcsTargetRecord],
    target: DefinitionTarget,
    arityKind: UfcsFormalArityKind,
    arity: uint32,
    requiredArity: uint32,
) =
  for existing in targets:
    if existing.target.sameDefinitionTarget(target):
      return
  targets.add UfcsTargetRecord(
    target: target, arityKind: arityKind, arity: arity, requiredArity: requiredArity
  )
