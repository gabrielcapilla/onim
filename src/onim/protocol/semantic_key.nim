import ../features/organize
import ../semantic/worker
import ../session/ids
import ../session/workspace_models

type SemanticKey* = object
  fileId*: FileId
  workKind*: SemanticWorkKind
  contentGeneration*: ContentGeneration
  dependencyGeneration*: DependencyGeneration
  configGeneration*: ConfigGeneration
  surfaceGeneration*: SurfaceGeneration
  useStdPrefix*: bool

proc semanticKey*(snapshot: WorkspaceSnapshot, options: OrganizeOptions): SemanticKey =
  SemanticKey(
    fileId: snapshot.fileId,
    workKind: semanticOrganize,
    contentGeneration: snapshot.contentGeneration,
    dependencyGeneration: snapshot.dependencyGeneration,
    configGeneration: snapshot.configGeneration,
    surfaceGeneration: snapshot.surfaceGeneration,
    useStdPrefix: options.useStdPrefix,
  )

proc semanticKey*(value: SemanticResult): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    workKind: value.workKind,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    surfaceGeneration: value.surfaceGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc semanticKey*(value: SemanticRequest): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    workKind: value.kind,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    surfaceGeneration: value.surfaceGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc sameSemanticKey*(left, right: SemanticKey): bool =
  left.fileId.value == right.fileId.value and left.workKind == right.workKind and
    left.contentGeneration.value == right.contentGeneration.value and
    left.dependencyGeneration.value == right.dependencyGeneration.value and
    left.configGeneration.value == right.configGeneration.value and
    left.surfaceGeneration.value == right.surfaceGeneration.value and
    left.useStdPrefix == right.useStdPrefix

proc sameSemanticGeneration*(left, right: SemanticKey): bool =
  left.fileId.value == right.fileId.value and
    left.contentGeneration.value == right.contentGeneration.value and
    left.dependencyGeneration.value == right.dependencyGeneration.value and
    left.configGeneration.value == right.configGeneration.value and
    left.surfaceGeneration.value == right.surfaceGeneration.value and
    left.useStdPrefix == right.useStdPrefix
