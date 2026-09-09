import std/[sets, tables]

import ../index/cache
import ../index/source_index
import ./bootstrap_validation
import ./bootstrap_worker
import ./disk_source
import ./ids
import ./workspace_file_ids
import ./workspace_models

proc applyBootstrapRecords*(
    bootstrapFiles: openArray[BootstrapFile],
    manifestByPath: Table[string, ManifestEntry],
    unresolved: HashSet[uint32],
    paths: var Table[string, FileId],
    files: var seq[FileRecord],
    nextFileId: var uint32,
    nextContentGeneration: var uint64,
): seq[FileId] =
  var present = initHashSet[string]()
  for bootstrapFile in bootstrapFiles:
    let path = bootstrapFile.path
    present.incl path
    if not paths.hasKey(path):
      let id = FileId(nextFileId)
      inc nextFileId
      paths[path] = id
      files.add FileRecord(
        id: id,
        path: path,
        state: workspaceMissing,
        version: -1,
        contentGeneration: InvalidContentGeneration,
        dependencyGeneration: InvalidDependencyGeneration,
        stamp: unknownStamp(),
        forward: @[],
        reverse: @[],
      )

  for index in 0 ..< files.len:
    if files[index].state != workspaceOpen and not present.contains(files[index].path) and
        files[index].state != workspaceMissing:
      addUniqueId(result, files[index].id)
      files[index].state = workspaceMissing
      files[index].text = ""
      files[index].textLoaded = true
      files[index].stamp = unknownStamp()
      files[index].index = indexSource("")
      files[index].contentGeneration = takeContentGeneration(nextContentGeneration)

  for bootstrapFile in bootstrapFiles:
    let id = paths[bootstrapFile.path]
    let index = id.recordIndex
    if files[index].state == workspaceOpen:
      continue
    let sameContent = sameBootstrapContent(files[index], bootstrapFile, manifestByPath)
    let sameGraph =
      sameBootstrapDependencies(files, paths, id, bootstrapFile.forward) and
      ((uint32(id) in unresolved) == bootstrapFile.unresolved)
    if not sameContent or not sameGraph:
      addUniqueId(result, id)
    files[index].state = workspaceOnDisk
    files[index].version = -1
    files[index].text = ""
    files[index].textLoaded = false
    files[index].stamp = bootstrapFile.stamp
    if not sameContent:
      files[index].index = nil
      files[index].contentGeneration = takeContentGeneration(nextContentGeneration)
