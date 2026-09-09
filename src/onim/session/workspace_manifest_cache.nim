import std/tables

import ../index/cache
import ../index/source_index
import ./ids
import ./disk_source
import ./workspace_file_ids
import ./workspace_models

proc cachedManifestIndex*(
    root: string,
    files: openArray[FileRecord],
    manifestByPath: Table[string, ManifestEntry],
    id: FileId,
    stamp: FileStamp,
): SourceIndex =
  let index = id.recordIndex
  if index < 0 or index >= files.len or files[index].state != workspaceOnDisk or
      not manifestByPath.hasKey(files[index].path):
    return
  let path = files[index].path
  let entry = manifestByPath[path]
  if entry.byteLength < 0 or entry.byteLength > int64(high(int)) or
      entry.byteLength != stamp.size:
    return
  loadCachedSourceIndexFingerprint(root, path, entry.sourceHash, int(entry.byteLength))

proc restoreManifestSourceIndex*(
    root, path: string,
    entry: ManifestEntry,
    currentStamp: FileStamp,
    file: var FileRecord,
): bool =
  if entry.byteLength != currentStamp.size or entry.byteLength > int64(high(int)):
    return false
  let stable = stableDiskSource(path)
  if not stable.valid or not sameFileStamp(stable.stamp, currentStamp) or
      stable.source.len != int(entry.byteLength) or
      contentFingerprint(stable.source) != entry.sourceHash:
    return false
  file.index = indexSource(stable.source)
  discard saveCachedSourceIndex(root, path, stable.source, file.index)
  true
