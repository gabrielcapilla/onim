import std/[algorithm, sets, strutils, tables]
import std/os except FileId

import ../index/cache
import ../index/source_index
import ../index/surfaces
import ../index/surface_project_input
import ./bootstrap_worker
import ./bootstrap_manifest
import ./bootstrap_paths
import ./bootstrap_validation
import ./ids
import ./module_catalog
import ./package_catalog
import ./paths
import ./disk_source
import ./source_discovery
import ./workspace_file_ids
import ./workspace_graph
import ./workspace_manifest_cache
import ./workspace_manifest_restore
import ./workspace_manifest_builder
import ./workspace_models
import ./workspace_catalog
import ./workspace_dependencies
import ./workspace_bootstrap_dependencies
import ./workspace_invalidation
import ./workspace_records
import ./workspace_surface_inputs
import ./workspace_missing_files
import ./workspace_disk_restore
import ./workspace_bootstrap_finalize
import ./workspace_manifest_persistence
import ./workspace_bootstrap_records
import ./workspace_text_index

type Workspace* = ref object
  root*: string
  manifest*: ProjectManifest
  bootstrapState*: WorkspaceBootstrapState
  bootstrapAttempt: ConfigGeneration
  snapshotId: SnapshotId
  configGeneration: ConfigGeneration
  workspaceGeneration: uint64
  nextFileId: uint32
  nextContentGeneration: uint64
  surfaceGeneration: SurfaceGeneration
  files: seq[FileRecord]
  paths: Table[string, FileId]
  manifestByPath: Table[string, ManifestEntry]
  invalidated: seq[FileId]
  unresolved: HashSet[uint32]
  moduleCatalogCache: ModuleCatalog
  projectSurfaceCache: SurfaceIndex
  projectSurfaceBuiltGeneration: SurfaceGeneration
  projectSurfaceInputs: seq[SurfaceInput]
  projectSurfaceInputGenerations: seq[uint64]
  projectSurfaceInputCandidateCounts: seq[uint32]

proc bootstrapPending*(workspace: Workspace): bool {.inline.} =
  workspace != nil and workspace.root.len > 0 and
    workspace.bootstrapState in {
      workspaceBootstrapPending, workspaceBootstrapIncomplete
    }

proc initWorkspace*(root = ""): Workspace =
  new(result)
  result.root = canonicalPath(root)
  result.bootstrapState = workspaceBootstrapPending
  result.bootstrapAttempt = InvalidConfigGeneration
  result.snapshotId = SnapshotId(1'u64)
  result.configGeneration = ConfigGeneration(1'u64)
  result.workspaceGeneration = 1
  result.nextFileId = 1
  result.nextContentGeneration = 1
  result.paths = initTable[string, FileId]()
  result.manifestByPath = initTable[string, ManifestEntry]()
  result.unresolved = initHashSet[uint32]()
  adoptManifest(
    result.manifest,
    result.manifestByPath,
    result.surfaceGeneration,
    loadProjectManifest(result.root),
  )

proc prepareWorkspace*(workspace: Workspace, root: string): bool =
  let canonicalRoot = canonicalPath(root)
  if canonicalRoot.len == 0:
    return false
  if canonicalRoot == workspace.root:
    return true
  if workspace.files.len > 0:
    return false
  workspace.root = canonicalRoot
  workspace.bootstrapState = workspaceBootstrapPending
  workspace.bootstrapAttempt = InvalidConfigGeneration
  bumpWorkspaceGeneration(workspace.workspaceGeneration)
  workspace.moduleCatalogCache = nil
  adoptManifest(
    workspace.manifest,
    workspace.manifestByPath,
    workspace.surfaceGeneration,
    loadProjectManifest(workspace.root),
  )
  true

proc prepareWorkspaceForDocument*(workspace: Workspace, path: string): bool =
  if workspace == nil:
    return false
  if workspace.root.len > 0:
    return true
  let root = nearestProjectRoot(path)
  root.len > 0 and not broadWorkspaceRoot(root) and workspace.prepareWorkspace(root)

proc markBootstrapIncomplete(workspace: Workspace) =
  if workspace.bootstrapState == workspaceBootstrapPending:
    workspace.bootstrapState = workspaceBootstrapIncomplete

proc moduleCatalog*(workspace: Workspace): ModuleCatalog =
  if workspace == nil:
    return
  if workspace.moduleCatalogCache != nil:
    return workspace.moduleCatalogCache
  workspace.moduleCatalogCache =
    buildWorkspaceModuleCatalog(workspace.root, workspace.files)
  workspace.moduleCatalogCache

proc cloneWorkspaceState(workspace: Workspace): Workspace =
  new(result)
  result.root = workspace.root
  result.manifest = cloneProjectManifest(workspace.manifest)
  result.bootstrapState = workspace.bootstrapState
  result.bootstrapAttempt = workspace.bootstrapAttempt
  result.snapshotId = workspace.snapshotId
  result.configGeneration = workspace.configGeneration
  result.workspaceGeneration = workspace.workspaceGeneration
  result.nextFileId = workspace.nextFileId
  result.nextContentGeneration = workspace.nextContentGeneration
  result.surfaceGeneration = workspace.surfaceGeneration
  result.files = newSeqOfCap[FileRecord](workspace.files.len)
  for file in workspace.files:
    result.files.add cloneFileRecord(file)
  result.paths = initTable[string, FileId]()
  for path, id in workspace.paths:
    result.paths[path] = id
  result.manifestByPath = initTable[string, ManifestEntry]()
  for path, entry in workspace.manifestByPath:
    result.manifestByPath[path] = entry
  result.invalidated = newSeqOfCap[FileId](workspace.invalidated.len)
  for id in workspace.invalidated:
    result.invalidated.add id
  result.unresolved = initHashSet[uint32]()
  for id in workspace.unresolved:
    result.unresolved.incl id

proc adoptWorkspaceState(destination, source: Workspace) =
  destination.root = source.root
  destination.manifest = source.manifest
  destination.bootstrapState = source.bootstrapState
  destination.bootstrapAttempt = source.bootstrapAttempt
  destination.snapshotId = source.snapshotId
  destination.configGeneration = source.configGeneration
  destination.workspaceGeneration = source.workspaceGeneration
  destination.nextFileId = source.nextFileId
  destination.nextContentGeneration = source.nextContentGeneration
  destination.surfaceGeneration = source.surfaceGeneration
  destination.files = source.files
  destination.paths = source.paths
  destination.manifestByPath = source.manifestByPath
  destination.invalidated = source.invalidated
  destination.unresolved = source.unresolved
  destination.moduleCatalogCache = source.moduleCatalogCache
  destination.projectSurfaceCache = source.projectSurfaceCache
  destination.projectSurfaceBuiltGeneration = source.projectSurfaceBuiltGeneration
  destination.projectSurfaceInputs = source.projectSurfaceInputs
  destination.projectSurfaceInputGenerations = source.projectSurfaceInputGenerations
  destination.projectSurfaceInputCandidateCounts =
    source.projectSurfaceInputCandidateCounts

proc applyBootstrap*(workspace: Workspace, value: BootstrapResult): bool =
  if workspace == nil or
      not validBootstrapResult(
        workspace.root,
        workspace.workspaceGeneration,
        uint64(workspace.configGeneration),
        value,
      ):
    return false

  var candidate = cloneWorkspaceState(workspace)
  let changedRoots = applyBootstrapRecords(
    value.files, candidate.manifestByPath, candidate.unresolved, candidate.paths,
    candidate.files, candidate.nextFileId, candidate.nextContentGeneration,
  )

  if changedRoots.len > 0:
    candidate.moduleCatalogCache = nil
    invalidateProjectSurface(candidate.surfaceGeneration)
  candidate.manifest = bootstrapManifest(value)
  candidate.manifestByPath.clear()
  for entry in candidate.manifest.entries:
    candidate.manifestByPath[entry.path] = entry
    candidate.bootstrapState = workspaceBootstrapComplete
    candidate.bootstrapAttempt = ConfigGeneration(value.configGeneration)
  try:
    if not applyBootstrapDependencies(
      candidate.files,
      candidate.paths,
      candidate.unresolved,
      candidate.moduleCatalog(),
      value,
    ):
      return false
    candidate.invalidated.setLen(0)
    invalidateBootstrapChanges(
      workspace.files, candidate.files, changedRoots, candidate.invalidated,
      candidate.snapshotId,
    )
  except CatchableError:
    return false

  let hasOpenDocuments = block:
    var found = false
    for file in candidate.files:
      if file.state == workspaceOpen:
        found = true
        break
    found
  adoptWorkspaceState(workspace, candidate)
  if not hasOpenDocuments:
    persistManifest(
      workspace.bootstrapState, workspace.root, workspace.manifest,
      workspace.manifestByPath, workspace.surfaceGeneration, workspace.files,
      workspace.paths, workspace.unresolved,
    )
  true

proc resolveModule*(workspace: Workspace, owner: FileId, reference: string): FileId =
  let index = owner.recordIndex
  if not owner.validRecordIndex(workspace.files.len) or
      workspace.files[index].state == workspaceMissing:
    return InvalidFileId
  resolveReference(workspace.moduleCatalog(), workspace.files[index].path, reference)

proc installText(
    workspace: Workspace,
    id: FileId,
    text: string,
    state: WorkspaceFileState,
    version: int64,
    invalidate: bool,
): bool =
  let index = id.recordIndex
  if not id.validRecordIndex(workspace.files.len):
    return false
  if not acceptsTextVersion(workspace.files[index], version):
    return false
  let previousText = workspace.files[index].text
  let previousIndex = workspace.files[index].index
  let stamp =
    if state == workspaceOnDisk:
      fileStamp(workspace.files[index].path)
    else:
      unknownStamp()
  let update = updateFileRecordText(workspace.files[index], text, state, version, stamp)
  let changed = update.changed
  let stateChanged = update.stateChanged
  if not changed:
    if stateChanged:
      workspace.moduleCatalogCache = nil
      invalidateProjectSurface(workspace.surfaceGeneration)
    return true

  if stateChanged:
    workspace.moduleCatalogCache = nil
  invalidateProjectSurface(workspace.surfaceGeneration)
  if invalidate:
    discard invalidateDependents(
      workspace.files, workspace.unresolved, workspace.invalidated,
      workspace.snapshotId, id,
    )
  workspace.files[index].index = indexWorkspaceText(
    workspace.root,
    workspace.files[index].path,
    text,
    previousText,
    previousIndex,
    state,
  )
  workspace.files[index].contentGeneration =
    takeContentGeneration(workspace.nextContentGeneration)
  replaceDependencies(
    workspace.files, id, workspace.moduleCatalog(), workspace.unresolved
  )
  true

proc installDiskText(
    workspace: Workspace, id: FileId, source: string, stamp: FileStamp, invalidate: bool
): bool =
  result = installText(workspace, id, source, workspaceOnDisk, -1, invalidate)
  if result:
    workspace.files[id.recordIndex].stamp = stamp

proc ensureText(workspace: Workspace, id: FileId, invalidate = true): bool =
  let index = id.recordIndex
  if not id.validRecordIndex(workspace.files.len):
    return false
  if workspace.files[index].state == workspaceOpen:
    return workspace.files[index].textLoaded

  let path = workspace.files[index].path
  let currentStamp = fileStamp(path)
  if currentStamp.size < 0:
    if workspace.files[index].state != workspaceMissing:
      discard installText(workspace, id, "", workspaceMissing, -1, invalidate)
      persistManifest(
        workspace.bootstrapState, workspace.root, workspace.manifest,
        workspace.manifestByPath, workspace.surfaceGeneration, workspace.files,
        workspace.paths, workspace.unresolved,
      )
    return false
  if diskTextCurrent(workspace.files[index], currentStamp):
    return true
  if workspace.files[index].state == workspaceOnDisk and
      workspace.files[index].index == nil:
    workspace.files[index].index = cachedManifestIndex(
      workspace.root, workspace.files, workspace.manifestByPath, id, currentStamp
    )

  let stable = stableDiskSource(path)
  if not stable.valid:
    discard installText(workspace, id, "", workspaceMissing, -1, invalidate)
    persistManifest(
      workspace.bootstrapState, workspace.root, workspace.manifest,
      workspace.manifestByPath, workspace.surfaceGeneration, workspace.files,
      workspace.paths, workspace.unresolved,
    )
    return false
  if reuseIndexedDiskText(workspace.files[index], stable.source, stable.stamp):
    return true
  let wasMissing = workspace.files[index].state == workspaceMissing
  discard workspace.installDiskText(id, stable.source, stable.stamp, invalidate)
  if wasMissing:
    rebuildDependencies(
      workspace.files, workspace.moduleCatalog(), workspace.unresolved
    )
    discard invalidateDependents(
      workspace.files, workspace.unresolved, workspace.invalidated,
      workspace.snapshotId, id, invalidationTopology,
    )
  persistManifest(
    workspace.bootstrapState, workspace.root, workspace.manifest,
    workspace.manifestByPath, workspace.surfaceGeneration, workspace.files,
    workspace.paths, workspace.unresolved,
  )
  true

proc ensureIndex(workspace: Workspace, id: FileId): bool =
  let index = id.recordIndex
  if not id.validRecordIndex(workspace.files.len):
    return false
  if workspace.files[index].state == workspaceMissing:
    return false
  if workspace.files[index].index != nil:
    return true
  if workspace.files[index].state == workspaceOpen:
    discard workspace.ensureText(id)
    return workspace.files[index].index != nil

  let path = workspace.files[index].path
  let currentStamp = fileStamp(path)
  if currentStamp.size < 0:
    discard workspace.ensureText(id)
    return false
  if workspace.files[index].state != workspaceOnDisk or
      not sameFileStamp(currentStamp, workspace.files[index].stamp):
    discard workspace.ensureText(id)
    return workspace.files[index].index != nil

  let cached = cachedManifestIndex(
    workspace.root, workspace.files, workspace.manifestByPath, id, currentStamp
  )
  if cached != nil:
    workspace.files[index].index = cached
    return true

  if workspace.manifestByPath.hasKey(path):
    let entry = workspace.manifestByPath[path]
    if restoreManifestSourceIndex(
      workspace.root, path, entry, currentStamp, workspace.files[index]
    ):
      return true

  discard workspace.ensureText(id)
  workspace.files[index].index != nil

proc indexWorkspaceImpl(workspace: Workspace): bool =
  if workspace.root.len == 0 or not dirExists(workspace.root):
    return false

  let hadRecords = workspace.files.len > 0
  let discovered = discoverSources(workspace.root, workspace.manifest)
  if discovered.status != discoveryComplete:
    return false
  let paths = discovered.paths

  var present = initTable[string, bool]()
  var topologyChanged = registerDiscoveredFiles(
    paths, present, workspace.paths, workspace.files, workspace.nextFileId,
    workspace.bootstrapState, workspace.moduleCatalogCache, hadRecords,
  )

  if markMissingDiscoveredFiles(
    workspace.files, present, hadRecords, workspace.nextContentGeneration
  ):
    topologyChanged = true

  var lazyRestored =
    not topologyChanged and workspace.manifest.graphValid and
    workspace.manifest.entries.len == workspace.files.len and
    paths.len == workspace.files.len
  if lazyRestored:
    lazyRestored = tryLazyManifestRestore(
      workspace.manifest, workspace.files, workspace.paths, workspace.manifestByPath,
      workspace.unresolved, workspace.nextContentGeneration,
    )

  for path in paths:
    let id = workspace.paths[path]
    if lazyRestored:
      continue
    if workspace.files[id.recordIndex].state == workspaceOpen:
      continue
    let wasMissing = workspace.files[id.recordIndex].state == workspaceMissing
    let stamp = fileStamp(path)
    if workspace.manifestByPath.hasKey(path):
      let entry = workspace.manifestByPath[path]
      if restoreCachedSourceIndex(
        workspace.root,
        path,
        entry,
        stamp,
        workspace.files[id.recordIndex],
        workspace.nextContentGeneration,
      ):
        continue
    if restoreDiskSource(
      workspace.root,
      path,
      workspace.files[id.recordIndex],
      hadRecords,
      workspace.nextContentGeneration,
    ):
      topologyChanged = true
  workspace.moduleCatalogCache = nil
  if not lazyRestored:
    restoreOrRebuildDependencies(
      workspace.root, workspace.manifest, workspace.files, workspace.paths,
      workspace.unresolved, topologyChanged, workspace.moduleCatalogCache,
    )
  finalizeWorkspaceIndex(
    workspace.root, workspace.bootstrapState, workspace.manifest,
    workspace.manifestByPath, workspace.files, workspace.paths, workspace.unresolved,
    workspace.invalidated, workspace.snapshotId, workspace.surfaceGeneration,
    discovered.directories, topologyChanged, lazyRestored,
  )
  true

proc indexWorkspace*(workspace: Workspace, root = "") =
  if root.len > 0 and not workspace.prepareWorkspace(root):
    return
  workspace.bootstrapState = workspaceBootstrapIncomplete
  discard workspace.indexWorkspaceImpl()

proc bootstrapWorkspace*(workspace: Workspace): bool =
  case workspace.bootstrapState
  of workspaceBootstrapComplete:
    return true
  of workspaceBootstrapFailed:
    if workspace.bootstrapAttempt.value == workspace.configGeneration.value:
      return false
    workspace.bootstrapState = workspaceBootstrapIncomplete
  of workspaceBootstrapPending, workspaceBootstrapIncomplete:
    discard
  if workspace.root.len == 0 or not dirExists(workspace.root):
    workspace.bootstrapState = workspaceBootstrapFailed
    return false
  workspace.bootstrapState = workspaceBootstrapFailed
  workspace.bootstrapAttempt = workspace.configGeneration
  try:
    result = workspace.indexWorkspaceImpl()
  except CatchableError:
    result = false
    workspace.bootstrapState = workspaceBootstrapFailed

proc fileIdForPath*(workspace: Workspace, path: string): FileId =
  let key = canonicalPath(path)
  if key.len > 0 and workspace.paths.hasKey(key):
    workspace.paths[key]
  else:
    InvalidFileId

proc isOpenDocument*(workspace: Workspace, path: string): bool =
  let id = workspace.fileIdForPath(path)
  id.valid and workspace.files[id.recordIndex].state == workspaceOpen

proc fileCount*(workspace: Workspace): int =
  workspace.files.len

proc fileIds*(workspace: Workspace): seq[FileId] =
  if workspace == nil:
    return
  result = newSeqOfCap[FileId](workspace.files.len)
  for file in workspace.files:
    if file.state != workspaceMissing:
      result.add file.id

proc dependencies*(workspace: Workspace, id: FileId): seq[FileId] =
  let index = id.recordIndex
  if id.validRecordIndex(workspace.files.len):
    result = newSeqOfCap[FileId](workspace.files[index].forward.len)
    for dependency in workspace.files[index].forward:
      result.add dependency

proc dependents*(workspace: Workspace, id: FileId): seq[FileId] =
  let index = id.recordIndex
  if id.validRecordIndex(workspace.files.len):
    result = newSeqOfCap[FileId](workspace.files[index].reverse.len)
    for dependent in workspace.files[index].reverse:
      result.add dependent

proc graphComplete*(workspace: Workspace): bool =
  workspace.bootstrapState == workspaceBootstrapComplete and
    workspace.unresolved.len == 0 and workspace.moduleCatalog().complete()

proc workspaceGeneration*(workspace: Workspace): uint64 =
  if workspace == nil: 0 else: workspace.workspaceGeneration

proc configurationGeneration*(workspace: Workspace): uint64 =
  if workspace == nil:
    0
  else:
    uint64(workspace.configGeneration)

proc openDocumentIds*(workspace: Workspace): seq[FileId] =
  if workspace == nil:
    return
  for file in workspace.files:
    if file.state == workspaceOpen:
      result.add file.id

proc drainInvalidated*(workspace: Workspace): seq[FileId] =
  result = newSeqOfCap[FileId](workspace.invalidated.len)
  for id in workspace.invalidated:
    result.add id
  workspace.invalidated = @[]

proc openDocument*(
    workspace: Workspace, uri, path, text: string, version: int64
): FileId =
  bumpWorkspaceGeneration(workspace.workspaceGeneration)
  let ensured = ensureRecord(
    path, workspace.paths, workspace.files, workspace.nextFileId,
    workspace.bootstrapState, workspace.moduleCatalogCache,
  )
  result = ensured.id
  if not result.valid:
    return
  workspace.files[result.recordIndex].uri = uri
  if not installText(workspace, result, text, workspaceOpen, version, true):
    return
  if ensured.created:
    rebuildDependencies(
      workspace.files, workspace.moduleCatalog(), workspace.unresolved
    )
    discard invalidateDependents(
      workspace.files, workspace.unresolved, workspace.invalidated,
      workspace.snapshotId, result, invalidationTopology,
    )

proc changeDocument*(
    workspace: Workspace, uri, path, text: string, version: int64
): bool =
  let known = workspace.fileIdForPath(path)
  if known.valid:
    let index = known.recordIndex
    if not acceptsTextVersion(workspace.files[index], version):
      return false
  bumpWorkspaceGeneration(workspace.workspaceGeneration)
  let ensured = ensureRecord(
    path, workspace.paths, workspace.files, workspace.nextFileId,
    workspace.bootstrapState, workspace.moduleCatalogCache,
  )
  if not ensured.id.valid:
    return false
  workspace.files[ensured.id.recordIndex].uri = uri
  result = installText(workspace, ensured.id, text, workspaceOpen, version, true)
  if ensured.created:
    rebuildDependencies(
      workspace.files, workspace.moduleCatalog(), workspace.unresolved
    )
    discard invalidateDependents(
      workspace.files, workspace.unresolved, workspace.invalidated,
      workspace.snapshotId, ensured.id, invalidationTopology,
    )

proc refreshDiskFile*(workspace: Workspace, path: string, deleted = false) =
  bumpWorkspaceGeneration(workspace.workspaceGeneration)
  let ensured = ensureRecord(
    path, workspace.paths, workspace.files, workspace.nextFileId,
    workspace.bootstrapState, workspace.moduleCatalogCache,
  )
  if not ensured.id.valid:
    return
  let index = ensured.id.recordIndex
  if workspace.files[index].state == workspaceOpen:
    return
  let wasMissing = workspace.files[index].state == workspaceMissing
  var topologyChanged = ensured.created or wasMissing
  if deleted or not fileExists(workspace.files[index].path):
    discard installText(workspace, ensured.id, "", workspaceMissing, -1, true)
    topologyChanged = not wasMissing
  else:
    let stable = stableDiskSource(workspace.files[index].path)
    if stable.valid:
      discard workspace.installDiskText(ensured.id, stable.source, stable.stamp, true)
    else:
      discard installText(workspace, ensured.id, "", workspaceMissing, -1, true)
      topologyChanged = not wasMissing
  if topologyChanged:
    workspace.moduleCatalogCache = nil
    rebuildDependencies(
      workspace.files, workspace.moduleCatalog(), workspace.unresolved
    )
    discard invalidateDependents(
      workspace.files, workspace.unresolved, workspace.invalidated,
      workspace.snapshotId, ensured.id, invalidationTopology,
    )
  persistManifest(
    workspace.bootstrapState, workspace.root, workspace.manifest,
    workspace.manifestByPath, workspace.surfaceGeneration, workspace.files,
    workspace.paths, workspace.unresolved,
  )

proc closeDocument*(workspace: Workspace, uri, path: string) =
  bumpWorkspaceGeneration(workspace.workspaceGeneration)
  let id = workspace.fileIdForPath(path)
  if not id.valid:
    return
  let index = id.recordIndex
  workspace.files[index].uri = uri
  let stable = stableDiskSource(workspace.files[index].path)
  if stable.valid:
    discard workspace.installDiskText(id, stable.source, stable.stamp, true)
  else:
    discard installText(workspace, id, "", workspaceMissing, -1, true)
    rebuildDependencies(
      workspace.files, workspace.moduleCatalog(), workspace.unresolved
    )
  persistManifest(
    workspace.bootstrapState, workspace.root, workspace.manifest,
    workspace.manifestByPath, workspace.surfaceGeneration, workspace.files,
    workspace.paths, workspace.unresolved,
  )

proc configurationChanged*(workspace: Workspace) =
  bumpWorkspaceGeneration(workspace.workspaceGeneration)
  workspace.configGeneration =
    ConfigGeneration(uint64(workspace.configGeneration) + 1'u64)
  workspace.moduleCatalogCache = nil
  rebuildDependencies(workspace.files, workspace.moduleCatalog(), workspace.unresolved)
  invalidateProjectSurface(workspace.surfaceGeneration)
  if workspace.bootstrapState == workspaceBootstrapFailed:
    workspace.bootstrapState = workspaceBootstrapIncomplete
  invalidateAll(workspace.files, workspace.invalidated, workspace.snapshotId)

proc fileChanged*(workspace: Workspace, path: string, deleted = false) =
  let lower = path.toLowerAscii
  if lower.endsWith("/nim.cfg") or lower.endsWith("/config.nims") or
      lower.endsWith(".nimble") or lower.endsWith(".cfg"):
    workspace.configurationChanged()
  elif lower.endsWith(".nim"):
    workspace.refreshDiskFile(path, deleted)

proc snapshotForDocument*(workspace: Workspace, uri, path: string): WorkspaceSnapshot =
  let id = workspace.fileIdForPath(path)
  if id.valid:
    discard workspace.ensureText(id)
  else:
    let ensured = ensureRecord(
      path, workspace.paths, workspace.files, workspace.nextFileId,
      workspace.bootstrapState, workspace.moduleCatalogCache,
    )
    if not ensured.id.valid:
      return
    if ensured.created:
      bumpWorkspaceGeneration(workspace.workspaceGeneration)
    discard workspace.ensureText(ensured.id, invalidate = false)
  let current = workspace.fileIdForPath(path)
  if not current.valid:
    return
  let index = current.recordIndex
  result = snapshotForRecord(
    workspace.files[index],
    workspace.snapshotId,
    workspace.configGeneration,
    workspace.surfaceGeneration,
    uri,
  )
  releaseDiskText(workspace.files[index])

proc snapshotForFile*(workspace: Workspace, id: FileId): WorkspaceSnapshot =
  let index = id.recordIndex
  if not id.validRecordIndex(workspace.files.len):
    return
  discard workspace.ensureText(id)
  result = snapshotForRecord(
    workspace.files[index],
    workspace.snapshotId,
    workspace.configGeneration,
    workspace.surfaceGeneration,
  )
  releaseDiskText(workspace.files[index])

proc indexViewForFile*(workspace: Workspace, id: FileId): WorkspaceIndexView =
  let index = id.recordIndex
  if not id.validRecordIndex(workspace.files.len):
    return
  discard workspace.ensureIndex(id)
  result = indexViewForRecord(workspace.files[index], workspace.snapshotId)

proc moduleForPath*(workspace: Workspace, path: string): string =
  workspace.moduleCatalog().moduleForPath(path)

proc projectSurface*(workspace: Workspace): SurfaceIndex =
  if workspace == nil:
    return
  if workspace.projectSurfaceCache != nil and
      workspace.projectSurfaceBuiltGeneration.value == workspace.surfaceGeneration.value:
    return workspace.projectSurfaceCache
  let catalog = workspace.moduleCatalog()
  let universeComplete = workspace.graphComplete()
  workspace.projectSurfaceInputs.setLen(workspace.files.len)
  workspace.projectSurfaceInputGenerations.setLen(workspace.files.len)
  workspace.projectSurfaceInputCandidateCounts.setLen(workspace.files.len)
  var contributors = newSeqOfCap[SurfaceContributor](workspace.files.len)
  for file in workspace.files:
    let fileIndex = file.id.recordIndex
    if not file.id.validRecordIndex(workspace.files.len) or
        file.state == workspaceMissing or not workspace.ensureIndex(file.id):
      if fileIndex >= 0 and fileIndex < workspace.projectSurfaceInputs.len:
        workspace.projectSurfaceInputs[fileIndex] = SurfaceInput()
        workspace.projectSurfaceInputGenerations[fileIndex] = 0
        workspace.projectSurfaceInputCandidateCounts[fileIndex] = 0
      continue
    let contribution = cachedProjectSurfaceContributor(
      workspace.root,
      workspace.files[fileIndex],
      catalog,
      workspace.projectSurfaceInputs,
      workspace.projectSurfaceInputGenerations,
      workspace.projectSurfaceInputCandidateCounts,
    )
    if contribution.hasModule:
      contributors.add contribution.contributor
  workspace.projectSurfaceCache = buildProjectSurfaceIndex(
    contributors, universeComplete, workspace.projectSurfaceCache
  )
  workspace.projectSurfaceBuiltGeneration = workspace.surfaceGeneration
  workspace.projectSurfaceCache
