import ../index/cache
import ../index/source_index
import ./ids

type
  WorkspaceBootstrapState* = enum
    workspaceBootstrapPending
    workspaceBootstrapIncomplete
    workspaceBootstrapComplete
    workspaceBootstrapFailed

  WorkspaceFileState* = enum
    workspaceMissing
    workspaceOnDisk
    workspaceOpen

  FileRecord* = object
    id*: FileId
    path*: string
    uri*: string
    text*: string
    textLoaded*: bool
    stamp*: FileStamp
    state*: WorkspaceFileState
    version*: int64
    contentGeneration*: ContentGeneration
    dependencyGeneration*: DependencyGeneration
    index*: SourceIndex
    forward*: seq[FileId]
    reverse*: seq[FileId]

  WorkspaceSnapshot* = object
    valid*: bool
    id*: SnapshotId
    fileId*: FileId
    path*: string
    uri*: string
    version*: int64
    text*: string
    state*: WorkspaceFileState
    contentGeneration*: ContentGeneration
    dependencyGeneration*: DependencyGeneration
    configGeneration*: ConfigGeneration
    surfaceGeneration*: SurfaceGeneration
    index*: SourceIndex

  WorkspaceIndexView* = object
    valid*: bool
    id*: SnapshotId
    fileId*: FileId
    path*: string
    uri*: string
    contentGeneration*: ContentGeneration
    index*: SourceIndex

proc takeContentGeneration*(counter: var uint64): ContentGeneration =
  result = ContentGeneration(counter)
  inc counter

proc cloneFileRecord*(file: FileRecord): FileRecord =
  result = file
  result.forward = newSeqOfCap[FileId](file.forward.len)
  for dependency in file.forward:
    result.forward.add dependency
  result.reverse = newSeqOfCap[FileId](file.reverse.len)
  for dependent in file.reverse:
    result.reverse.add dependent

proc cloneProjectManifest*(value: ProjectManifest): ProjectManifest =
  result = value
  result.directories = newSeqOfCap[ManifestDirectory](value.directories.len)
  for directory in value.directories:
    result.directories.add directory
  result.entries = newSeqOfCap[ManifestEntry](value.entries.len)
  for entry in value.entries:
    var copied = entry
    copied.forwardOrdinals = newSeqOfCap[uint32](entry.forwardOrdinals.len)
    for ordinal in entry.forwardOrdinals:
      copied.forwardOrdinals.add ordinal
    result.entries.add copied

proc snapshotForRecord*(
    file: FileRecord,
    snapshotId: SnapshotId,
    configGeneration: ConfigGeneration,
    surfaceGeneration: SurfaceGeneration,
    uriOverride = "",
): WorkspaceSnapshot =
  result.valid = file.state != workspaceMissing
  result.id = snapshotId
  result.fileId = file.id
  result.path = file.path
  result.uri = if uriOverride.len > 0: uriOverride else: file.uri
  result.version = file.version
  result.text = file.text
  result.state = file.state
  result.contentGeneration = file.contentGeneration
  result.dependencyGeneration = file.dependencyGeneration
  result.configGeneration = configGeneration
  result.surfaceGeneration = surfaceGeneration
  result.index = file.index

proc indexViewForRecord*(file: FileRecord, snapshotId: SnapshotId): WorkspaceIndexView =
  result.valid = file.state != workspaceMissing
  result.id = snapshotId
  result.fileId = file.id
  result.path = file.path
  result.uri = file.uri
  result.contentGeneration = file.contentGeneration
  result.index = file.index

proc releaseDiskText*(file: var FileRecord) =
  if file.state == workspaceOnDisk:
    file.text = ""
    file.textLoaded = false

proc reuseIndexedDiskText*(
    file: var FileRecord, source: string, stamp: FileStamp
): bool =
  if file.state != workspaceOnDisk or file.index == nil or
      file.index.contentHash != contentFingerprint(source) or
      file.index.byteLength != source.len:
    return false
  file.text = source
  file.textLoaded = true
  file.stamp = stamp
  true

proc acceptsTextVersion*(file: FileRecord, version: int64): bool =
  file.state != workspaceOpen or version < 0 or file.version < 0 or
    version > file.version

proc diskTextCurrent*(file: FileRecord, stamp: FileStamp): bool =
  file.state == workspaceOnDisk and file.textLoaded and sameFileStamp(stamp, file.stamp)

proc updateFileRecordText*(
    file: var FileRecord,
    text: string,
    state: WorkspaceFileState,
    version: int64,
    stamp: FileStamp,
): tuple[changed: bool, stateChanged: bool] =
  result.stateChanged = file.state != state
  result.changed =
    if file.textLoaded:
      file.index == nil or file.text != text
    else:
      file.index == nil or file.index.contentHash != contentFingerprint(text) or
        file.index.byteLength != text.len
  file.state = state
  if version >= 0 or state != workspaceOpen or file.version < 0:
    file.version = version
  file.text = text
  file.textLoaded = true
  file.stamp = stamp
