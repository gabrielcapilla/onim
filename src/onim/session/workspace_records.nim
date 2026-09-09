import std/tables

import ./disk_source
import ./ids
import ./module_catalog
import ./paths
import ./workspace_file_ids
import ./workspace_models

proc ensureRecord*(
    path: string,
    paths: var Table[string, FileId],
    files: var seq[FileRecord],
    nextFileId: var uint32,
    bootstrapState: var WorkspaceBootstrapState,
    moduleCatalogCache: var ModuleCatalog,
): tuple[id: FileId, created: bool] =
  let key = canonicalPath(path)
  if key.len == 0:
    return (InvalidFileId, false)
  if paths.hasKey(key):
    return (paths[key], false)

  let id = FileId(nextFileId)
  inc nextFileId
  if bootstrapState == workspaceBootstrapPending:
    bootstrapState = workspaceBootstrapIncomplete
  moduleCatalogCache = nil
  paths[key] = id
  files.add FileRecord(
    id: id,
    path: key,
    state: workspaceMissing,
    version: -1,
    contentGeneration: InvalidContentGeneration,
    dependencyGeneration: InvalidDependencyGeneration,
    textLoaded: false,
    stamp: unknownStamp(),
    forward: @[],
    reverse: @[],
  )
  (id, true)

proc registerDiscoveredFiles*(
    discoveredPaths: openArray[string],
    present: var Table[string, bool],
    paths: var Table[string, FileId],
    files: var seq[FileRecord],
    nextFileId: var uint32,
    bootstrapState: var WorkspaceBootstrapState,
    moduleCatalogCache: var ModuleCatalog,
    hadRecords: bool,
): bool =
  for path in discoveredPaths:
    present[path] = true
    let ensured =
      ensureRecord(path, paths, files, nextFileId, bootstrapState, moduleCatalogCache)
    if hadRecords and ensured.created:
      result = true
    elif hadRecords and files[ensured.id.recordIndex].state == workspaceMissing:
      result = true
