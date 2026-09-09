import ../index/source_index
import ./disk_source
import ./ids
import ./workspace_models

proc restoreDiskSource*(
    root, path: string,
    file: var FileRecord,
    hadRecords: bool,
    nextContentGeneration: var uint64,
): bool =
  let wasMissing = file.state == workspaceMissing
  let stable = stableDiskSource(path)
  if stable.valid:
    let indexed = indexDiskSource(root, path, stable.source)
    let sameContent =
      file.state == workspaceOnDisk and file.index != nil and indexed != nil and
      file.index.contentHash == indexed.contentHash and
      file.index.byteLength == indexed.byteLength
    file.text = stable.source
    file.textLoaded = true
    file.state = workspaceOnDisk
    file.version = -1
    file.stamp = stable.stamp
    if not sameContent:
      file.index = indexed
      file.contentGeneration = takeContentGeneration(nextContentGeneration)
    file.text = ""
    file.textLoaded = false
    return hadRecords and wasMissing

  file.state = workspaceMissing
  file.text = ""
  file.textLoaded = true
  file.stamp = unknownStamp()
  file.index = indexSource("")
  hadRecords and not wasMissing
