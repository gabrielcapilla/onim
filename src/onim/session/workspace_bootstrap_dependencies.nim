import std/[sets, tables]

import ./bootstrap_worker
import ./ids
import ./module_catalog
import ./workspace_dependencies
import ./workspace_file_ids
import ./workspace_models

proc applyBootstrapDependencies*(
    files: var seq[FileRecord],
    paths: Table[string, FileId],
    unresolved: var HashSet[uint32],
    catalog: ModuleCatalog,
    value: BootstrapResult,
): bool =
  unresolved.clear()
  for file in files.mitems:
    file.reverse.setLen(0)
    if file.state != workspaceOpen:
      file.forward.setLen(0)

  for bootstrapFile in value.files:
    if not paths.hasKey(bootstrapFile.path):
      return false
    let id = paths[bootstrapFile.path]
    let index = id.recordIndex
    if index < 0 or index >= files.len:
      return false
    if files[index].state == workspaceOpen:
      replaceDependencies(files, id, catalog, unresolved)
      continue
    for dependencyPath in bootstrapFile.forward:
      if not paths.hasKey(dependencyPath):
        return false
      addUniqueId(files[index].forward, paths[dependencyPath])
    files[index].forward.sortIds
    if bootstrapFile.unresolved:
      unresolved.incl uint32(id)

  for file in files:
    for dependency in file.forward:
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= files.len:
        return false
      addUniqueId(files[dependencyIndex].reverse, file.id)
  for file in files.mitems:
    file.reverse.sortIds
  true
