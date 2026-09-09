import ../features/organize
import ../semantic/worker
import ../session/ids
import ../session/workspace
import ../session/workspace_models

type SemanticKey* = object
  fileId*: FileId
  contentGeneration*: ContentGeneration
  dependencyGeneration*: DependencyGeneration
  configGeneration*: ConfigGeneration
  surfaceGeneration*: SurfaceGeneration
  useStdPrefix*: bool

proc semanticKey*(snapshot: WorkspaceSnapshot, options: OrganizeOptions): SemanticKey =
  SemanticKey(
    fileId: snapshot.fileId,
    contentGeneration: snapshot.contentGeneration,
    dependencyGeneration: snapshot.dependencyGeneration,
    configGeneration: snapshot.configGeneration,
    surfaceGeneration: snapshot.surfaceGeneration,
    useStdPrefix: options.useStdPrefix,
  )

proc semanticKey*(value: SemanticResult): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    surfaceGeneration: value.surfaceGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc semanticKey*(value: SemanticRequest): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    surfaceGeneration: value.surfaceGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc sameSemanticKey*(left, right: SemanticKey): bool =
  left.fileId.value == right.fileId.value and
    left.contentGeneration.value == right.contentGeneration.value and
    left.dependencyGeneration.value == right.dependencyGeneration.value and
    left.configGeneration.value == right.configGeneration.value and
    left.surfaceGeneration.value == right.surfaceGeneration.value and
    left.useStdPrefix == right.useStdPrefix
