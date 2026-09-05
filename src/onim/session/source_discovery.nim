import std/[algorithm, os, strutils, tables]

import ../index/cache
import ./paths

type
  DiscoveryStatus* = enum
    discoveryComplete
    discoveryCancelled
    discoveryFailed

  DiscoveryCancellation* = proc(): bool {.gcsafe.}

  DiscoveryResult* = object
    status*: DiscoveryStatus
    paths*: seq[string]
    directories*: seq[ManifestDirectory]
    directoriesVisited*: uint32
    directoriesReused*: uint32
    directoriesPruned*: uint32
    entriesExamined*: uint32
    errorPath*: string

  DiscoveryState = object
    root: string
    cancellation: DiscoveryCancellation
    oldDirectories: Table[string, ManifestDirectory]
    oldFiles: Table[string, bool]
    currentStamps: Table[string, FileStamp]
    changedDirectories: seq[string]
    outputDirectories: Table[string, FileStamp]
    outputFiles: Table[string, bool]
    output: DiscoveryResult
    cancelled: bool
    failed: bool
    unstable: bool

const prunedDirectoryNames = [".git", ".cache", "nimcache"]

proc shouldCancel(cancellation: DiscoveryCancellation): bool {.inline.} =
  cancellation != nil and cancellation()

proc prunedDirectory(path: string): bool {.inline.} =
  let name = lastPathPart(path).toLowerAscii
  for candidate in prunedDirectoryNames:
    if name == candidate:
      return true
  false

proc nimSourcePath(path: string): bool {.inline.} =
  path.toLowerAscii.endsWith(".nim")

proc pathWithin(root, path: string): bool {.inline.} =
  path == root or path.startsWith(root & "/")

proc markCancelled(state: var DiscoveryState) {.inline.} =
  state.cancelled = true
  state.output.status = discoveryCancelled
  state.output.errorPath = state.root

proc markFailed(state: var DiscoveryState, path: string) {.inline.} =
  state.failed = true
  state.output.status = discoveryFailed
  state.output.errorPath = path

proc addDirectory(state: var DiscoveryState, path: string, stamp: FileStamp) =
  state.outputDirectories[path] = stamp

proc addFile(state: var DiscoveryState, path: string) =
  state.outputFiles[path] = true

proc subtreeChanged(state: DiscoveryState, directory: string): bool {.inline.} =
  for changed in state.changedDirectories:
    if pathWithin(directory, changed):
      return true
  false

proc changedDirectory(state: DiscoveryState, directory: string): bool {.inline.} =
  for changed in state.changedDirectories:
    if changed == directory:
      return true
  false

proc restoreSubtree(state: var DiscoveryState, directory: string): bool {.gcsafe.} =
  if not state.oldDirectories.hasKey(directory):
    state.markFailed(directory)
    return false
  for path, _ in state.oldDirectories:
    if not pathWithin(directory, path):
      continue
    if not state.currentStamps.hasKey(path) or not usableStamp(
      state.currentStamps[path]
    ):
      state.markFailed(path)
      return false
    state.addDirectory(path, state.currentStamps[path])
    inc state.output.directoriesReused
  for path, _ in state.oldFiles:
    if pathWithin(directory, path):
      state.addFile(path)
  true

proc scanDirectory(state: var DiscoveryState, directory: string): bool {.gcsafe.}

proc rebuildSubtree(state: var DiscoveryState, directory: string): bool {.gcsafe.} =
  if state.cancelled or state.failed:
    return false
  if shouldCancel(state.cancellation):
    state.markCancelled()
    return false
  if changedDirectory(state, directory):
    return state.scanDirectory(directory)
  if not state.oldDirectories.hasKey(directory):
    return state.scanDirectory(directory)
  if not state.currentStamps.hasKey(directory):
    state.markFailed(directory)
    return false
  state.addDirectory(directory, state.currentStamps[directory])
  inc state.output.directoriesReused
  for path, _ in state.oldDirectories:
    if path == directory or not pathWithin(directory, path):
      continue
    if parentDir(path) != directory:
      continue
    if state.subtreeChanged(path):
      if not state.rebuildSubtree(path):
        return false
    elif not state.restoreSubtree(path):
      return false
  for path, _ in state.oldFiles:
    if parentDir(path) == directory:
      state.addFile(path)
  true

proc scanDirectory(state: var DiscoveryState, directory: string): bool {.gcsafe.} =
  if state.cancelled or state.failed:
    return false
  if shouldCancel(state.cancellation):
    state.markCancelled()
    return false
  let before = fileStamp(directory)
  if not usableStamp(before):
    state.markFailed(directory)
    return false
  state.addDirectory(directory, before)
  inc state.output.directoriesVisited
  try:
    for kind, rawPath in walkDir(directory):
      if shouldCancel(state.cancellation):
        state.markCancelled()
        return false
      inc state.output.entriesExamined
      let path = canonicalPath(rawPath)
      if path.len == 0 or not pathWithin(state.root, path):
        state.markFailed(rawPath)
        return false
      case kind
      of pcDir:
        if prunedDirectory(path):
          inc state.output.directoriesPruned
        elif state.oldDirectories.hasKey(path) and not state.subtreeChanged(path):
          if not state.restoreSubtree(path):
            return false
        elif not state.scanDirectory(path):
          return false
      of pcFile:
        if nimSourcePath(path):
          state.addFile(path)
      else:
        discard
  except CatchableError:
    state.markFailed(directory)
    return false
  let after = fileStamp(directory)
  if not usableStamp(after):
    state.markFailed(directory)
    return false
  if not sameFileStamp(before, after):
    state.unstable = true
    return false
  state.outputDirectories[directory] = after
  true

proc finish(state: DiscoveryState): DiscoveryResult {.gcsafe.} =
  result = state.output
  if state.cancelled:
    result.status = discoveryCancelled
    result.paths.setLen(0)
    result.directories.setLen(0)
    return
  if state.failed or state.unstable:
    result.status = discoveryFailed
    result.paths.setLen(0)
    result.directories.setLen(0)
    return
  var paths = newSeqOfCap[string](state.outputFiles.len)
  for path, _ in state.outputFiles:
    paths.add path
  paths.sort
  result.paths = paths
  var directories = newSeqOfCap[ManifestDirectory](state.outputDirectories.len)
  for path, stamp in state.outputDirectories:
    directories.add ManifestDirectory(path: path, stamp: stamp)
  directories.sort(
    proc(left, right: ManifestDirectory): int =
      cmp(left.path, right.path)
  )
  result.directories = directories
  result.status = discoveryComplete

proc initState(
    root: string, cancellation: DiscoveryCancellation
): DiscoveryState {.gcsafe.} =
  result.root = root
  result.cancellation = cancellation
  result.oldDirectories = initTable[string, ManifestDirectory]()
  result.oldFiles = initTable[string, bool]()
  result.currentStamps = initTable[string, FileStamp]()
  result.outputDirectories = initTable[string, FileStamp]()
  result.outputFiles = initTable[string, bool]()
  result.output.status = discoveryFailed
  result.output.errorPath = root

proc fullDiscovery(
    root: string, cancellation: DiscoveryCancellation
): DiscoveryResult {.gcsafe.} =
  for _ in 0 .. 1:
    var state = initState(root, cancellation)
    if state.scanDirectory(root):
      return state.finish()
    if state.cancelled:
      return state.finish()
    if not state.unstable:
      return state.finish()
  result.status = discoveryFailed
  result.errorPath = root

proc prepareWarmState(
    root: string, previous: ProjectManifest, cancellation: DiscoveryCancellation
): tuple[available: bool, state: DiscoveryState] {.gcsafe.} =
  result.state = initState(root, cancellation)
  if not previous.discoveryValid or previous.root != root or
      previous.directories.len == 0:
    return
  var hasRoot = false
  for directory in previous.directories:
    let path = canonicalPath(directory.path)
    if path.len == 0 or path != directory.path or not pathWithin(root, path) or
        not usableStamp(directory.stamp) or result.state.oldDirectories.hasKey(path):
      return
    result.state.oldDirectories[path] = directory
    if path == root:
      hasRoot = true
  if not hasRoot:
    return
  for entry in previous.entries:
    let path = canonicalPath(entry.path)
    if path.len == 0 or path != entry.path or not pathWithin(root, path) or
        not nimSourcePath(path) or result.state.oldFiles.hasKey(path):
      return
    result.state.oldFiles[path] = true
    if not fileExists(path):
      return
  for path, directory in result.state.oldDirectories:
    if shouldCancel(cancellation):
      result.state.markCancelled()
      return (true, result.state)
    let current = fileStamp(path)
    if not usableStamp(current):
      return
    result.state.currentStamps[path] = current
    if not sameFileStamp(current, directory.stamp):
      result.state.changedDirectories.add path
  result.available = true

proc incrementalDiscovery(
    root: string, previous: ProjectManifest, cancellation: DiscoveryCancellation
): tuple[available: bool, value: DiscoveryResult] {.gcsafe.} =
  let prepared = prepareWarmState(root, previous, cancellation)
  if not prepared.available:
    return
  if prepared.state.cancelled:
    result.available = true
    result.value = prepared.state.finish()
    return
  var state = prepared.state
  if state.changedDirectories.len == 0:
    discard state.restoreSubtree(root)
    result.available = true
    result.value = state.finish()
    return
  if state.rebuildSubtree(root):
    result.available = true
    result.value = state.finish()
  elif state.cancelled:
    result.available = true
    result.value = state.finish()

proc discoverSources*(
    root: string, previous: ProjectManifest, cancellation: DiscoveryCancellation = nil
): DiscoveryResult {.gcsafe.} =
  let canonicalRoot = canonicalPath(root)
  if canonicalRoot.len == 0 or not dirExists(canonicalRoot):
    result.status = discoveryFailed
    result.errorPath = canonicalRoot
    return
  if shouldCancel(cancellation):
    result.status = discoveryCancelled
    result.errorPath = canonicalRoot
    return
  let incremental = incrementalDiscovery(canonicalRoot, previous, cancellation)
  if incremental.available:
    if incremental.value.status == discoveryComplete or
        incremental.value.status == discoveryCancelled:
      return incremental.value
  fullDiscovery(canonicalRoot, cancellation)

proc discoverSources*(
    root: string, cancellation: DiscoveryCancellation = nil
): DiscoveryResult {.gcsafe.} =
  discoverSources(root, ProjectManifest(), cancellation)
