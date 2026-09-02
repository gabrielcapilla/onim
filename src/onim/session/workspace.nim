import std/[algorithm, strutils, tables]
import std/os except FileId

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
    snapshotId: SnapshotId
    configGeneration: ConfigGeneration
    nextFileId: uint32
    nextContentGeneration: uint64
    files: seq[FileRecord]
    paths: Table[string, FileId]
    invalidated: seq[FileId]
    unresolvedFiles: int

proc canonicalPath(path: string): string =
  if path.len == 0:
    return ""
  absolutePath(path)

proc initWorkspace*(root = ""): Workspace =
  new(result)
  result.root = canonicalPath(root)
  result.snapshotId = SnapshotId(1'u64)
  result.configGeneration = ConfigGeneration(1'u64)
  result.nextFileId = 1
  result.nextContentGeneration = 1
  result.paths = initTable[string, FileId]()

proc bumpSnapshot(workspace: Workspace) =
  workspace.snapshotId = SnapshotId(uint64(workspace.snapshotId) + 1'u64)

proc nextContent(workspace: Workspace): ContentGeneration =
  result = ContentGeneration(workspace.nextContentGeneration)
  inc workspace.nextContentGeneration

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
      return workspace.paths[key]
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
    workspace.files[index].index == nil or workspace.files[index].text != text
  workspace.files[index].state = state
  workspace.files[index].version = version
  if not changed:
    return true

  if invalidate:
    discard invalidateDependents(workspace, id)
  workspace.files[index].text = text
  workspace.files[index].index = indexSource(text)
  workspace.files[index].contentGeneration = workspace.nextContent()
  replaceDependencies(workspace, id)
  true

proc indexWorkspace*(workspace: Workspace, root = "") =
  if root.len > 0:
    workspace.root = canonicalPath(root)
  if workspace.root.len == 0 or not dirExists(workspace.root):
    return

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

  for path in paths:
    discard ensureRecord(workspace, path)
  for path in paths:
    let id = workspace.paths[path]
    if workspace.files[id.recordIndex].state == workspaceOpen:
      continue
    try:
      workspace.files[id.recordIndex].text = readFile(path)
      workspace.files[id.recordIndex].state = workspaceOnDisk
      workspace.files[id.recordIndex].version = -1
      workspace.files[id.recordIndex].index =
        indexSource(workspace.files[id.recordIndex].text)
      workspace.files[id.recordIndex].contentGeneration = workspace.nextContent()
    except CatchableError:
      workspace.files[id.recordIndex].state = workspaceMissing
      workspace.files[id.recordIndex].text = ""
      workspace.files[id.recordIndex].index = indexSource("")
  rebuildDependencies(workspace)
  workspace.bumpSnapshot()

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
  if deleted or not fileExists(workspace.files[index].path):
    discard installText(workspace, ensured.id, "", workspaceMissing, -1, true)
  else:
    try:
      discard installText(
        workspace,
        ensured.id,
        readFile(workspace.files[index].path),
        workspaceOnDisk,
        -1,
        true,
      )
    except CatchableError:
      discard installText(workspace, ensured.id, "", workspaceMissing, -1, true)
  if ensured.created:
    rebuildDependencies(workspace)

proc closeDocument*(workspace: Workspace, uri, path: string) =
  let id = workspace.fileIdForPath(path)
  if not id.valid:
    return
  let index = id.recordIndex
  workspace.files[index].uri = uri
  if fileExists(workspace.files[index].path):
    try:
      discard installText(
        workspace, id, readFile(workspace.files[index].path), workspaceOnDisk, -1, true
      )
    except CatchableError:
      discard installText(workspace, id, "", workspaceMissing, -1, true)
  else:
    discard installText(workspace, id, "", workspaceMissing, -1, true)

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
    let index = id.recordIndex
    if workspace.files[index].state != workspaceOpen:
      workspace.refreshDiskFile(path)
  else:
    let ensured = ensureRecord(workspace, path)
    if not ensured.id.valid:
      return
    try:
      discard
        installText(workspace, ensured.id, readFile(path), workspaceOnDisk, -1, false)
    except CatchableError:
      discard installText(workspace, ensured.id, "", workspaceMissing, -1, false)
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
