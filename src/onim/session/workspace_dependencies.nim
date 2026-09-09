import std/[sets, strutils, tables]

import ../index/cache
import ./ids
import ./module_catalog
import ./workspace_catalog
import ./workspace_file_ids
import ./workspace_manifest_restore
import ./workspace_models

proc resolveReference*(catalog: ModuleCatalog, ownerPath, reference: string): FileId =
  let resolution = catalog.resolve(ownerPath, reference)
  if resolution.kind == moduleResolved: resolution.id else: InvalidFileId

proc replaceDependencies*(
    files: var seq[FileRecord],
    id: FileId,
    catalog: ModuleCatalog,
    unresolved: var HashSet[uint32],
) =
  let index = id.recordIndex
  if index < 0 or index >= files.len:
    return

  let oldForward = files[index].forward
  for dependency in oldForward:
    let dependencyIndex = dependency.recordIndex
    if dependencyIndex >= 0 and dependencyIndex < files.len:
      removeId(files[dependencyIndex].reverse, id)

  files[index].forward.setLen(0)
  var hasUnresolved = false
  if files[index].index != nil:
    for reference in files[index].index.imports:
      let dependency = resolveReference(catalog, files[index].path, reference)
      if dependency.valid:
        addUniqueId(files[index].forward, dependency)
      elif not reference.startsWith("std/") and reference != "std":
        hasUnresolved = true
    for reference in files[index].index.includes:
      let dependency = resolveReference(catalog, files[index].path, reference)
      if dependency.valid:
        addUniqueId(files[index].forward, dependency)
      else:
        hasUnresolved = true

  sortIds(files[index].forward)
  for dependency in files[index].forward:
    let dependencyIndex = dependency.recordIndex
    if dependencyIndex >= 0 and dependencyIndex < files.len:
      addUniqueId(files[dependencyIndex].reverse, id)
      sortIds(files[dependencyIndex].reverse)

  let fileId = uint32(files[index].id)
  if hasUnresolved:
    unresolved.incl fileId
  else:
    unresolved.excl fileId

proc rebuildDependencies*(
    files: var seq[FileRecord], catalog: ModuleCatalog, unresolved: var HashSet[uint32]
) =
  unresolved.clear()
  for file in files.mitems:
    file.forward.setLen(0)
    file.reverse.setLen(0)
  for index in 0 ..< files.len:
    replaceDependencies(files, files[index].id, catalog, unresolved)

proc restoreOrRebuildDependencies*(
    root: string,
    manifest: ProjectManifest,
    files: var seq[FileRecord],
    paths: Table[string, FileId],
    unresolved: var HashSet[uint32],
    topologyChanged: bool,
    moduleCatalogCache: var ModuleCatalog,
) =
  if not topologyChanged and restoreDependencies(manifest, files, paths, unresolved):
    return
  if moduleCatalogCache == nil:
    moduleCatalogCache = buildWorkspaceModuleCatalog(root, files)
  rebuildDependencies(files, moduleCatalogCache, unresolved)
