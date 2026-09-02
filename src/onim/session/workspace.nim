import std/[algorithm, strutils, tables]
import std/os except FileId

import ../index/cache
import ../index/source_index
import ./ids

type
  WorkspaceFileState* = enum
    workspaceMissing
    workspaceOnDisk
    workspaceOpen

  WorkspaceSnapshot* = object
    valid*: bool
    id*: SnapshotId
    fileId*: FileId
    path*: string
    uri*: string
    text*: string
    state*: WorkspaceFileState
    contentGeneration*: ContentGeneration
    dependencyGeneration*: DependencyGeneration
    configGeneration*: ConfigGeneration
    index*: SourceIndex

  FileRecord = object
    id: FileId
    path: string
    uri: string
    text: string
    textLoaded: bool
    stamp: FileStamp
    state: WorkspaceFileState
    version: int64
    contentGeneration: ContentGeneration
    dependencyGeneration: DependencyGeneration
    index: SourceIndex
    forward: seq[FileId]
    reverse: seq[FileId]
    unresolved: bool

  Workspace* = ref object
    root*: string
    manifest*: ProjectManifest
    snapshotId: SnapshotId
    configGeneration: ConfigGeneration
    nextFileId: uint32
    nextContentGeneration: uint64
    files: seq[FileRecord]
    paths: Table[string, FileId]
    manifestByPath: Table[string, ManifestEntry]
    invalidated: seq[FileId]
    unresolvedFiles: int

proc canonicalPath(path: string): string =
  if path.len == 0:
    return ""
  absolutePath(path)

proc unknownStamp(): FileStamp =
  FileStamp(size: -1, modifiedSeconds: -1, modifiedNanoseconds: -1)

proc adoptManifest(workspace: Workspace, manifest: ProjectManifest) =
  workspace.manifest = manifest
  workspace.manifestByPath.clear()
  for entry in manifest.entries:
    workspace.manifestByPath[entry.path] = entry

proc initWorkspace*(root = ""): Workspace =
  new(result)
  result.root = canonicalPath(root)
  result.snapshotId = SnapshotId(1'u64)
  result.configGeneration = ConfigGeneration(1'u64)
  result.nextFileId = 1
  result.nextContentGeneration = 1
  result.paths = initTable[string, FileId]()
  result.manifestByPath = initTable[string, ManifestEntry]()
  result.adoptManifest(loadProjectManifest(result.root))

proc bumpSnapshot(workspace: Workspace) =
  workspace.snapshotId = SnapshotId(uint64(workspace.snapshotId) + 1'u64)

proc nextContent(workspace: Workspace): ContentGeneration =
  result = ContentGeneration(workspace.nextContentGeneration)
  inc workspace.nextContentGeneration

proc indexDiskSource(workspace: Workspace, path, source: string): SourceIndex =
  result = loadCachedSourceIndex(workspace.root, path, source)
  if result == nil:
    result = indexSource(source)
    discard saveCachedSourceIndex(workspace.root, path, source, result)

proc persistManifest(workspace: Workspace) =
  var entries: seq[ManifestEntry] = @[]
  var graphValid = true
  for index in 0 ..< workspace.files.len:
    let file = workspace.files[index]
    if file.state != workspaceOnDisk or file.index == nil:
      graphValid = false
      continue
    let stamp = fileStamp(file.path)
    if stamp.size < 0 or file.stamp.size < 0 or not sameFileStamp(stamp, file.stamp):
      graphValid = false
      continue
    entries.add ManifestEntry(
      path: file.path,
      sourceHash: file.index.contentHash,
      byteLength: int64(file.index.byteLength),
      stamp: stamp,
      unresolved: file.unresolved,
    )
  graphValid = graphValid and entries.len == workspace.files.len
  entries.sort(
    proc(left, right: ManifestEntry): int =
      cmp(left.path, right.path)
  )
  if graphValid:
    var ordinals = initTable[string, uint32]()
    for ordinal, entry in entries:
      ordinals[entry.path] = uint32(ordinal)
    for ordinal, entry in entries:
      let id = workspace.paths[entry.path]
      for dependency in workspace.files[id.slot].forward:
        let dependencyIndex = dependency.slot
        if dependencyIndex < 0 or dependencyIndex >= workspace.files.len or
            workspace.files[dependencyIndex].state != workspaceOnDisk or
            not ordinals.hasKey(workspace.files[dependencyIndex].path):
          graphValid = false
          break
        entries[ordinal].forwardOrdinals.add(
          ordinals[workspace.files[dependencyIndex].path]
        )
      if not graphValid:
        break
      entries[ordinal].forwardOrdinals.sort
  workspace.adoptManifest(
    ProjectManifest(root: workspace.root, entries: entries, graphValid: graphValid)
  )
  discard saveProjectManifest(workspace.root, entries, graphValid)

proc ensureRecord(
    workspace: Workspace, path: string
): tuple[id: FileId, created: bool] =
  let key = canonicalPath(path)
  if key.len == 0:
    return (InvalidFileId, false)
  if workspace.paths.hasKey(key):
    return (workspace.paths[key], false)

  let id = FileId(workspace.nextFileId)
  inc workspace.nextFileId
  workspace.paths[key] = id
  workspace.files.add FileRecord(
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

proc recordIndex(id: FileId): int =
  id.slot

proc addUniqueId(values: var seq[FileId], value: FileId) =
  if not value.valid:
    return
  for existing in values:
    if uint32(existing) == uint32(value):
      return
  values.add value

proc sortIds(values: var seq[FileId]) =
  values.sort(
    proc(left, right: FileId): int =
      cmp(uint32(left), uint32(right))
  )

proc removeId(values: var seq[FileId], value: FileId) =
  var writeIndex = 0
  for current in values:
    if uint32(current) != uint32(value):
      values[writeIndex] = current
      inc writeIndex
  values.setLen(writeIndex)

proc addPathCandidate(candidates: var seq[string], path: string) =
  if path.len == 0:
    return
  let key = canonicalPath(path)
  for existing in candidates:
    if existing == key:
      return
  candidates.add key

proc resolveReference(workspace: Workspace, ownerPath, reference: string): FileId =
  let normalized = reference.strip
  if normalized.len == 0 or normalized.startsWith("std/"):
    return InvalidFileId

  var candidates: seq[string] = @[]
  if isAbsolute(normalized):
    addPathCandidate(candidates, normalized)
  else:
    addPathCandidate(candidates, splitFile(ownerPath).dir / normalized)
    if workspace.root.len > 0:
      addPathCandidate(candidates, workspace.root / normalized)

  for candidate in candidates:
    var modulePath = candidate
    if not modulePath.toLowerAscii.endsWith(".nim"):
      modulePath.add ".nim"
    let key = canonicalPath(modulePath)
    if workspace.paths.hasKey(key):
      let id = workspace.paths[key]
      let index = id.recordIndex
      if index >= 0 and index < workspace.files.len and
          workspace.files[index].state != workspaceMissing:
        return id
  InvalidFileId

proc replaceDependencies(workspace: Workspace, id: FileId) =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return

  let oldForward = workspace.files[index].forward
  for dependency in oldForward:
    let dependencyIndex = dependency.recordIndex
    if dependencyIndex >= 0 and dependencyIndex < workspace.files.len:
      removeId(workspace.files[dependencyIndex].reverse, id)

  workspace.files[index].forward.setLen(0)
  var unresolved = false
  if workspace.files[index].index != nil:
    for reference in workspace.files[index].index.imports:
      let dependency =
        resolveReference(workspace, workspace.files[index].path, reference)
      if dependency.valid:
        addUniqueId(workspace.files[index].forward, dependency)
      elif not reference.startsWith("std/") and reference != "std":
        unresolved = true
    for reference in workspace.files[index].index.exports:
      let dependency =
        resolveReference(workspace, workspace.files[index].path, reference)
      if dependency.valid:
        addUniqueId(workspace.files[index].forward, dependency)
      elif not reference.startsWith("std/") and reference != "std":
        unresolved = true
    for reference in workspace.files[index].index.includes:
      let dependency =
        resolveReference(workspace, workspace.files[index].path, reference)
      if dependency.valid:
        addUniqueId(workspace.files[index].forward, dependency)
      else:
        unresolved = true

  sortIds(workspace.files[index].forward)
  for dependency in workspace.files[index].forward:
    let dependencyIndex = dependency.recordIndex
    if dependencyIndex >= 0 and dependencyIndex < workspace.files.len:
      addUniqueId(workspace.files[dependencyIndex].reverse, id)
      sortIds(workspace.files[dependencyIndex].reverse)

  if unresolved != workspace.files[index].unresolved:
    if unresolved:
      inc workspace.unresolvedFiles
    else:
      dec workspace.unresolvedFiles
    workspace.files[index].unresolved = unresolved

proc rebuildDependencies(workspace: Workspace) =
  workspace.unresolvedFiles = 0
  for file in workspace.files.mitems:
    file.forward.setLen(0)
    file.reverse.setLen(0)
    file.unresolved = false
  for index in 0 ..< workspace.files.len:
    replaceDependencies(workspace, workspace.files[index].id)

proc restoreDependencies(workspace: Workspace): bool =
  if not workspace.manifest.graphValid or
      workspace.manifest.entries.len != workspace.files.len:
    return false

  var seen = newSeq[bool](workspace.files.len)
  var idsByOrdinal = newSeq[FileId](workspace.manifest.entries.len)
  var unresolvedFiles = 0
  for ordinal, entry in workspace.manifest.entries:
    if not workspace.paths.hasKey(entry.path):
      return false
    let id = workspace.paths[entry.path]
    let index = id.recordIndex
    if index < 0 or index >= workspace.files.len or seen[index] or entry.byteLength < 0 or
        entry.byteLength > int64(high(int)) or
        workspace.files[index].state != workspaceOnDisk or
        workspace.files[index].index == nil or
        not sameFileStamp(workspace.files[index].stamp, entry.stamp) or
        workspace.files[index].index.contentHash != entry.sourceHash or
        workspace.files[index].index.byteLength != int(entry.byteLength):
      return false
    seen[index] = true
    idsByOrdinal[ordinal] = id
    workspace.files[index].unresolved = entry.unresolved
    if entry.unresolved:
      inc unresolvedFiles

  for index in 0 ..< workspace.files.len:
    if not seen[index]:
      return false
    workspace.files[index].forward = @[]
  for ordinal, entry in workspace.manifest.entries:
    let index = idsByOrdinal[ordinal].recordIndex
    var previousOrdinal = uint32(0)
    for dependencyOrdinal in entry.forwardOrdinals:
      if dependencyOrdinal >= uint32(idsByOrdinal.len) or (
        workspace.files[index].forward.len > 0 and dependencyOrdinal <= previousOrdinal
      ):
        return false
      let dependency = idsByOrdinal[int(dependencyOrdinal)]
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= workspace.files.len or
          workspace.files[dependencyIndex].state == workspaceMissing:
        return false
      workspace.files[index].forward.add dependency
      previousOrdinal = dependencyOrdinal

  for index in 0 ..< workspace.files.len:
    workspace.files[index].reverse.setLen(0)
  for index in 0 ..< workspace.files.len:
    for dependency in workspace.files[index].forward:
      let dependencyIndex = dependency.recordIndex
      if dependencyIndex < 0 or dependencyIndex >= workspace.files.len:
        return false
      addUniqueId(workspace.files[dependencyIndex].reverse, workspace.files[index].id)
  for file in workspace.files.mitems:
    file.forward.sortIds
    file.reverse.sortIds
  workspace.unresolvedFiles = unresolvedFiles
  true

proc allFileIds(workspace: Workspace): seq[FileId] =
  result = newSeqOfCap[FileId](workspace.files.len)
  for file in workspace.files:
    result.add file.id

proc reverseClosure(workspace: Workspace, root: FileId): seq[FileId] =
  if not root.valid:
    return
  var seen = newSeq[bool](workspace.files.len)
  var queue = @[root]
  var head = 0
  while head < queue.len:
    let current = queue[head]
    inc head
    let index = current.recordIndex
    if index < 0 or index >= workspace.files.len or seen[index]:
      continue
    seen[index] = true
    result.add current
    for dependent in workspace.files[index].reverse:
      queue.add dependent
  result.sortIds

proc invalidateDependents(workspace: Workspace, root: FileId): seq[FileId] =
  if workspace.unresolvedFiles > 0:
    result = allFileIds(workspace)
  else:
    result = reverseClosure(workspace, root)
  if result.len == 0:
    return
  workspace.bumpSnapshot()
  for id in result:
    let index = id.recordIndex
    workspace.files[index].dependencyGeneration =
      DependencyGeneration(uint64(workspace.snapshotId))
    addUniqueId(workspace.invalidated, id)
  sortIds(workspace.invalidated)

proc invalidateAll(workspace: Workspace) =
  workspace.bumpSnapshot()
  for file in workspace.files.mitems:
    file.dependencyGeneration = DependencyGeneration(uint64(workspace.snapshotId))
    addUniqueId(workspace.invalidated, file.id)
  sortIds(workspace.invalidated)

proc installText(
    workspace: Workspace,
    id: FileId,
    text: string,
    state: WorkspaceFileState,
    version: int64,
    invalidate: bool,
): bool =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return false
  if workspace.files[index].state == workspaceOpen and version >= 0 and
      workspace.files[index].version >= 0 and version <= workspace.files[index].version:
    return false

  let changed =
    if workspace.files[index].textLoaded:
      workspace.files[index].index == nil or workspace.files[index].text != text
    else:
      workspace.files[index].index == nil or
        workspace.files[index].index.contentHash != contentFingerprint(text) or
        workspace.files[index].index.byteLength != text.len
  workspace.files[index].state = state
  workspace.files[index].version = version
  workspace.files[index].text = text
  workspace.files[index].textLoaded = true
  workspace.files[index].stamp =
    if state == workspaceOnDisk:
      fileStamp(workspace.files[index].path)
    else:
      unknownStamp()
  if not changed:
    return true

  if invalidate:
    discard invalidateDependents(workspace, id)
  workspace.files[index].index =
    if state == workspaceOnDisk:
      workspace.indexDiskSource(workspace.files[index].path, text)
    else:
      indexSource(text)
  workspace.files[index].contentGeneration = workspace.nextContent()
  replaceDependencies(workspace, id)
  true

proc installDiskText(
    workspace: Workspace, id: FileId, source: string, stamp: FileStamp, invalidate: bool
): bool =
  result = installText(workspace, id, source, workspaceOnDisk, -1, invalidate)
  if result:
    workspace.files[id.recordIndex].stamp = stamp

proc stableDiskSource(
    path: string
): tuple[valid: bool, source: string, stamp: FileStamp] =
  for _ in 0 .. 1:
    let before = fileStamp(path)
    if before.size < 0:
      return
    try:
      let source = readFile(path)
      let after = fileStamp(path)
      if sameFileStamp(before, after) and after.size == int64(source.len):
        return (true, source, after)
    except CatchableError:
      return

proc ensureText(workspace: Workspace, id: FileId, invalidate = true): bool =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return false
  if workspace.files[index].state == workspaceOpen:
    return workspace.files[index].textLoaded

  let path = workspace.files[index].path
  let currentStamp = fileStamp(path)
  if currentStamp.size < 0:
    if workspace.files[index].state != workspaceMissing:
      discard installText(workspace, id, "", workspaceMissing, -1, invalidate)
      workspace.persistManifest()
    return false
  if workspace.files[index].state == workspaceOnDisk and
      workspace.files[index].textLoaded and
      sameFileStamp(currentStamp, workspace.files[index].stamp):
    return true

  let stable = stableDiskSource(path)
  if not stable.valid:
    discard installText(workspace, id, "", workspaceMissing, -1, invalidate)
    workspace.persistManifest()
    return false
  let sourceHash = contentFingerprint(stable.source)
  if workspace.files[index].state == workspaceOnDisk and
      workspace.files[index].index != nil and
      workspace.files[index].index.contentHash == sourceHash and
      workspace.files[index].index.byteLength == stable.source.len:
    workspace.files[index].text = stable.source
    workspace.files[index].textLoaded = true
    workspace.files[index].stamp = stable.stamp
    return true
  let wasMissing = workspace.files[index].state == workspaceMissing
  discard workspace.installDiskText(id, stable.source, stable.stamp, invalidate)
  if wasMissing:
    workspace.rebuildDependencies()
  workspace.persistManifest()
  true

proc indexWorkspace*(workspace: Workspace, root = "") =
  if root.len > 0:
    let canonicalRoot = canonicalPath(root)
    if canonicalRoot != workspace.root:
      if workspace.files.len > 0:
        return
      workspace.root = canonicalRoot
      workspace.adoptManifest(loadProjectManifest(workspace.root))
  if workspace.root.len == 0 or not dirExists(workspace.root):
    return

  let hadRecords = workspace.files.len > 0
  var paths: seq[string] = @[]
  try:
    for path in walkDirRec(workspace.root):
      let normalized = canonicalPath(path)
      let lower = normalized.toLowerAscii
      if not lower.endsWith(".nim") or lower.contains("/.git/") or
          lower.contains("/nimcache/") or lower.contains("/.cache/"):
        continue
      paths.add normalized
  except CatchableError:
    return
  paths.sort

  var present = initTable[string, bool]()
  var topologyChanged = false
  for path in paths:
    present[path] = true
    let ensured = ensureRecord(workspace, path)
    if hadRecords and ensured.created:
      topologyChanged = true

  for index in 0 ..< workspace.files.len:
    if workspace.files[index].state != workspaceOpen and
        not present.hasKey(workspace.files[index].path) and
        workspace.files[index].state != workspaceMissing:
      workspace.files[index].state = workspaceMissing
      workspace.files[index].text = ""
      workspace.files[index].textLoaded = true
      workspace.files[index].stamp = unknownStamp()
      workspace.files[index].index = indexSource("")
      workspace.files[index].contentGeneration = workspace.nextContent()
      if hadRecords:
        topologyChanged = true

  for path in paths:
    let id = workspace.paths[path]
    if workspace.files[id.recordIndex].state == workspaceOpen:
      continue
    let wasMissing = workspace.files[id.recordIndex].state == workspaceMissing
    let stamp = fileStamp(path)
    if workspace.manifestByPath.hasKey(path):
      let entry = workspace.manifestByPath[path]
      if stamp.size == entry.byteLength and sameFileStamp(stamp, entry.stamp) and
          entry.byteLength <= int64(high(int)):
        let cached = loadCachedSourceIndexFingerprint(
          workspace.root, path, entry.sourceHash, int(entry.byteLength)
        )
        if cached != nil:
          workspace.files[id.recordIndex].state = workspaceOnDisk
          workspace.files[id.recordIndex].version = -1
          workspace.files[id.recordIndex].text = ""
          workspace.files[id.recordIndex].textLoaded = false
          workspace.files[id.recordIndex].stamp = stamp
          workspace.files[id.recordIndex].index = cached
          workspace.files[id.recordIndex].contentGeneration = workspace.nextContent()
          continue
    let stable = stableDiskSource(path)
    if stable.valid:
      workspace.files[id.recordIndex].text = stable.source
      workspace.files[id.recordIndex].textLoaded = true
      workspace.files[id.recordIndex].state = workspaceOnDisk
      workspace.files[id.recordIndex].version = -1
      workspace.files[id.recordIndex].stamp = stable.stamp
      workspace.files[id.recordIndex].index =
        workspace.indexDiskSource(path, stable.source)
      workspace.files[id.recordIndex].contentGeneration = workspace.nextContent()
      workspace.files[id.recordIndex].text = ""
      workspace.files[id.recordIndex].textLoaded = false
      if hadRecords and wasMissing:
        topologyChanged = true
    else:
      workspace.files[id.recordIndex].state = workspaceMissing
      workspace.files[id.recordIndex].text = ""
      workspace.files[id.recordIndex].textLoaded = true
      workspace.files[id.recordIndex].stamp = unknownStamp()
      workspace.files[id.recordIndex].index = indexSource("")
      if hadRecords and not wasMissing:
        topologyChanged = true
  let restored = not topologyChanged and workspace.restoreDependencies()
  if not restored:
    rebuildDependencies(workspace)
  if topologyChanged:
    workspace.invalidateAll()
  else:
    workspace.bumpSnapshot()
  workspace.persistManifest()

proc fileIdForPath*(workspace: Workspace, path: string): FileId =
  let key = canonicalPath(path)
  if key.len > 0 and workspace.paths.hasKey(key):
    workspace.paths[key]
  else:
    InvalidFileId

proc fileCount*(workspace: Workspace): int =
  workspace.files.len

proc dependencies*(workspace: Workspace, id: FileId): seq[FileId] =
  let index = id.recordIndex
  if index >= 0 and index < workspace.files.len:
    result = newSeqOfCap[FileId](workspace.files[index].forward.len)
    for dependency in workspace.files[index].forward:
      result.add dependency

proc dependents*(workspace: Workspace, id: FileId): seq[FileId] =
  let index = id.recordIndex
  if index >= 0 and index < workspace.files.len:
    result = newSeqOfCap[FileId](workspace.files[index].reverse.len)
    for dependent in workspace.files[index].reverse:
      result.add dependent

proc graphComplete*(workspace: Workspace): bool =
  workspace.unresolvedFiles == 0

proc drainInvalidated*(workspace: Workspace): seq[FileId] =
  result = newSeqOfCap[FileId](workspace.invalidated.len)
  for id in workspace.invalidated:
    result.add id
  workspace.invalidated = @[]

proc openDocument*(
    workspace: Workspace, uri, path, text: string, version: int64
): FileId =
  let ensured = ensureRecord(workspace, path)
  result = ensured.id
  if not result.valid:
    return
  workspace.files[result.recordIndex].uri = uri
  if ensured.created and workspace.files.len > 1:
    discard
  if not installText(workspace, result, text, workspaceOpen, version, true):
    return
  if ensured.created:
    rebuildDependencies(workspace)

proc changeDocument*(
    workspace: Workspace, uri, path, text: string, version: int64
): bool =
  let ensured = ensureRecord(workspace, path)
  if not ensured.id.valid:
    return false
  workspace.files[ensured.id.recordIndex].uri = uri
  result = installText(workspace, ensured.id, text, workspaceOpen, version, true)
  if ensured.created:
    rebuildDependencies(workspace)

proc refreshDiskFile*(workspace: Workspace, path: string, deleted = false) =
  let ensured = ensureRecord(workspace, path)
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
    rebuildDependencies(workspace)
  workspace.persistManifest()

proc closeDocument*(workspace: Workspace, uri, path: string) =
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
    rebuildDependencies(workspace)
  workspace.persistManifest()

proc configurationChanged*(workspace: Workspace) =
  workspace.configGeneration =
    ConfigGeneration(uint64(workspace.configGeneration) + 1'u64)
  invalidateAll(workspace)

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
    let ensured = ensureRecord(workspace, path)
    if not ensured.id.valid:
      return
    discard workspace.ensureText(ensured.id, invalidate = false)
  let current = workspace.fileIdForPath(path)
  if not current.valid:
    return
  let index = current.recordIndex
  result.valid = workspace.files[index].state != workspaceMissing
  result.id = workspace.snapshotId
  result.fileId = current
  result.path = workspace.files[index].path
  result.uri =
    if uri.len > 0:
      uri
    else:
      workspace.files[index].uri
  result.text = workspace.files[index].text
  result.state = workspace.files[index].state
  result.contentGeneration = workspace.files[index].contentGeneration
  result.dependencyGeneration = workspace.files[index].dependencyGeneration
  result.configGeneration = workspace.configGeneration
  result.index = workspace.files[index].index

proc snapshotForFile*(workspace: Workspace, id: FileId): WorkspaceSnapshot =
  let index = id.recordIndex
  if index < 0 or index >= workspace.files.len:
    return
  discard workspace.ensureText(id)
  result.valid = workspace.files[index].state != workspaceMissing
  result.id = workspace.snapshotId
  result.fileId = id
  result.path = workspace.files[index].path
  result.uri = workspace.files[index].uri
  result.text = workspace.files[index].text
  result.state = workspace.files[index].state
  result.contentGeneration = workspace.files[index].contentGeneration
  result.dependencyGeneration = workspace.files[index].dependencyGeneration
  result.configGeneration = workspace.configGeneration
  result.index = workspace.files[index].index
