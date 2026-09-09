import std/[sets, tables]

import ../index/cache
import ./ids
import ./workspace_file_ids
import ./workspace_models

type DependencyRestoreMode* = enum
  restoreIndexed
  restoreLazy

proc restoreDependencies*(
    manifest: ProjectManifest,
    files: var seq[FileRecord],
    paths: Table[string, FileId],
    unresolved: var HashSet[uint32],
    mode = restoreIndexed,
): bool =
  if not manifest.graphValid or manifest.entries.len != files.len:
    return false

  var seen = newSeq[bool](files.len)
  var idsByOrdinal = newSeq[FileId](manifest.entries.len)
  unresolved.clear()
  for ordinal, entry in manifest.entries:
    if not paths.hasKey(entry.path):
      return false
    let id = paths[entry.path]
    let index = id.recordIndex
    if index < 0 or index >= files.len or seen[index] or entry.byteLength < 0 or
        entry.byteLength > int64(high(int)) or files[index].state != workspaceOnDisk or
        (mode == restoreIndexed and files[index].index == nil) or
        not sameFileStamp(files[index].stamp, entry.stamp):
      return false
    if files[index].index != nil and (
      files[index].index.contentHash != entry.sourceHash or
      files[index].index.byteLength != int(entry.byteLength)
    ):
      return false
    seen[index] = true
    idsByOrdinal[ordinal] = id
    if entry.unresolved:
      unresolved.incl uint32(id)

  for index in 0 ..< files.len:
    if not seen[index]:
      return false
    files[index].forward = @[]
  for ordinal, entry in manifest.entries:
    let index = idsByOrdinal[ordinal].recordIndex
    var previousOrdinal = uint32(0)
    for dependencyOrdinal in entry.forwardOrdinals:
      if dependencyOrdinal >= uint32(idsByOrdinal.len) or
          (files[index].forward.len > 0 and dependencyOrdinal <= previousOrdinal):
        return false
      let dependency = idsByOrdinal[int(dependencyOrdinal)]
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= files.len or
          files[dependencyIndex].state == workspaceMissing:
        return false
      files[index].forward.add dependency
      previousOrdinal = dependencyOrdinal

  for index in 0 ..< files.len:
    files[index].reverse.setLen(0)
  for index in 0 ..< files.len:
    for dependency in files[index].forward:
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= files.len:
        return false
      addUniqueId(files[dependencyIndex].reverse, files[index].id)
  for file in files.mitems:
    file.forward.sortIds
    file.reverse.sortIds
  true

proc tryLazyManifestRestore*(
    manifest: ProjectManifest,
    files: var seq[FileRecord],
    paths: Table[string, FileId],
    manifestByPath: Table[string, ManifestEntry],
    unresolved: var HashSet[uint32],
    nextContentGeneration: var uint64,
): bool =
  for path in paths.keys:
    let id = paths[path]
    let index = id.recordIndex
    if index < 0 or index >= files.len or files[index].state == workspaceOpen or
        not manifestByPath.hasKey(path):
      return false
    let entry = manifestByPath[path]
    let stamp = fileStamp(path)
    if entry.byteLength < 0 or entry.byteLength > int64(high(int)) or
        stamp.size != entry.byteLength or not sameFileStamp(stamp, entry.stamp):
      return false
  for path in paths.keys:
    let id = paths[path]
    let index = id.recordIndex
    let entry = manifestByPath[path]
    let sameContent =
      files[index].state == workspaceOnDisk and files[index].index != nil and
      files[index].index.contentHash == entry.sourceHash and
      files[index].index.byteLength == int(entry.byteLength)
    files[index].state = workspaceOnDisk
    files[index].version = -1
    files[index].text = ""
    files[index].textLoaded = false
    files[index].stamp = entry.stamp
    if not sameContent:
      files[index].index = nil
      files[index].contentGeneration = takeContentGeneration(nextContentGeneration)
  restoreDependencies(manifest, files, paths, unresolved, restoreLazy)

proc restoreCachedSourceIndex*(
    projectRoot, path: string,
    entry: ManifestEntry,
    stamp: FileStamp,
    file: var FileRecord,
    nextContentGeneration: var uint64,
): bool =
  if stamp.size != entry.byteLength or not sameFileStamp(stamp, entry.stamp) or
      entry.byteLength > int64(high(int)):
    return false
  let cached = loadCachedSourceIndexFingerprint(
    projectRoot, path, entry.sourceHash, int(entry.byteLength)
  )
  if cached == nil:
    return false
  let sameContent =
    file.state == workspaceOnDisk and file.index != nil and
    file.index.contentHash == entry.sourceHash and
    file.index.byteLength == int(entry.byteLength)
  file.state = workspaceOnDisk
  file.version = -1
  file.text = ""
  file.textLoaded = false
  file.stamp = stamp
  if not sameContent:
    file.index = cached
    file.contentGeneration = takeContentGeneration(nextContentGeneration)
  true
