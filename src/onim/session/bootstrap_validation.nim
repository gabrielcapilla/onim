import std/[sets, tables]

import ../index/cache
import ../index/source_index
import ./bootstrap_paths
import ./bootstrap_worker
import ./paths
import ./ids
import ./workspace_file_ids
import ./workspace_models

proc validBootstrapResult*(
    root: string,
    workspaceGeneration: uint64,
    configGeneration: uint64,
    value: BootstrapResult,
): bool =
  if value.kind != bootstrapComplete or canonicalPath(value.root) != root or
      value.workspaceGeneration != workspaceGeneration or
      value.configGeneration != configGeneration:
    return false
  if value.discoveryValid:
    if value.directories.len == 0:
      return false
    var directoryPaths = initHashSet[string]()
    var previousDirectory = ""
    var hasRoot = false
    for directory in value.directories:
      let path = canonicalPath(directory.path)
      if path != directory.path or not validBootstrapDirectoryPath(root, path) or
          path in directoryPaths or
          (previousDirectory.len > 0 and path <= previousDirectory) or
          not usableStamp(directory.stamp):
        return false
      directoryPaths.incl path
      previousDirectory = path
      hasRoot = hasRoot or path == root
    if not hasRoot:
      return false
  var paths = initHashSet[string]()
  var previousPath = ""
  for file in value.files:
    let path = canonicalPath(file.path)
    if path != file.path or not validBootstrapPath(root, path) or path in paths or
        (previousPath.len > 0 and path <= previousPath) or file.byteLength < 0 or
        file.stamp.size < 0 or file.stamp.modifiedNanoseconds < -1 or
        file.stamp.modifiedNanoseconds >= 1_000_000_000:
      return false
    paths.incl path
    previousPath = path
  for file in value.files:
    var previousDependency = ""
    for dependency in file.forward:
      let normalized = canonicalPath(dependency)
      if normalized != dependency or not paths.contains(normalized) or
          (previousDependency.len > 0 and dependency <= previousDependency):
        return false
      previousDependency = dependency
  true

proc sameBootstrapContent*(
    file: FileRecord,
    bootstrapFile: BootstrapFile,
    manifestByPath: Table[string, ManifestEntry],
): bool =
  if file.state != workspaceOnDisk:
    return false
  if file.index != nil:
    return
      file.index.contentHash == bootstrapFile.sourceHash and
      file.index.byteLength == bootstrapFile.byteLength
  if file.textLoaded:
    return
      contentFingerprint(file.text) == bootstrapFile.sourceHash and
      file.text.len == bootstrapFile.byteLength
  if manifestByPath.hasKey(file.path):
    let entry = manifestByPath[file.path]
    return
      entry.sourceHash == bootstrapFile.sourceHash and
      entry.byteLength == int64(bootstrapFile.byteLength)
  false

proc sameBootstrapDependencies*(
    files: openArray[FileRecord],
    paths: Table[string, FileId],
    id: FileId,
    forward: openArray[string],
): bool =
  let index = id.recordIndex
  if index < 0 or index >= files.len:
    return false
  var expected = newSeqOfCap[FileId](forward.len)
  for path in forward:
    if not paths.hasKey(path):
      return false
    expected.add paths[path]
  expected.sortIds
  if files[index].forward.len != expected.len:
    return false
  for position in 0 ..< expected.len:
    if uint32(files[index].forward[position]) != uint32(expected[position]):
      return false
  true
