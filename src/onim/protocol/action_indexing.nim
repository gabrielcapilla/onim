import ../features/organize
import ../features/organize_edits
import ../index/surfaces
import ../session/module_catalog
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ../stdlib/map_runtime
import ./action_cache

proc actionIsCurrent*(
    action: CachedAction, snapshot: WorkspaceSnapshot, options: OrganizeOptions
): bool =
  action.contentGeneration.value == snapshot.contentGeneration.value and
    action.dependencyGeneration.value == snapshot.dependencyGeneration.value and
    action.configGeneration.value == snapshot.configGeneration.value and
    action.surfaceGeneration.value == snapshot.surfaceGeneration.value and
    action.useStdPrefix == options.useStdPrefix

proc cacheIndexedAction*(
    workspace: Workspace,
    snapshot: WorkspaceSnapshot,
    options: OrganizeOptions,
    stdlib: var StdlibMap,
    actionCache: var seq[CachedAction],
): tuple[handled: bool, edits: seq[ImportEdit]] =
  if not snapshot.valid:
    return
  if stdlib == nil:
    stdlib = stdlibMap()
  var project: SurfaceIndex
  var catalog: ModuleCatalog
  var owner = ""
  if workspace.graphComplete:
    project = workspace.projectSurface()
    catalog = workspace.moduleCatalog()
    owner = workspace.moduleForPath(snapshot.path)
  let attempt = tryOrganizeSourceWithIndex(
    snapshot.path, snapshot.text, snapshot.index, stdlib, options, project, catalog,
    owner,
  )
  if not attempt.handled:
    return
  result.handled = true
  result.edits = attempt.edits
  storeCachedAction(
    actionCache,
    snapshot.fileId,
    CachedAction(
      contentGeneration: snapshot.contentGeneration,
      dependencyGeneration: snapshot.dependencyGeneration,
      configGeneration: snapshot.configGeneration,
      surfaceGeneration: snapshot.surfaceGeneration,
      useStdPrefix: options.useStdPrefix,
      edits: result.edits,
    ),
  )
