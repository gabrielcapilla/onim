import std/[algorithm, os, sets, strutils, tables]

import ../index/cache
import ./discovery_budget
import ./package_catalog
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

  DiscoveryAttemptState = enum
    discoveryAttemptRunning
    discoveryAttemptCancelled
    discoveryAttemptFailed
    discoveryAttemptLimited
    discoveryAttemptUnstable

  DiscoveryState = object
    root: string
    cancellation: DiscoveryCancellation
    oldDirectories: Table[string, ManifestDirectory]
    oldFiles: HashSet[string]
    currentStamps: Table[string, FileStamp]
    changedDirectories: seq[string]
    outputDirectories: Table[string, FileStamp]
    outputFiles: HashSet[string]
    budget: DiscoveryBudget
    output: DiscoveryResult
    attempt: DiscoveryAttemptState

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

proc markCancelled(state: var DiscoveryState) {.inline.} =
  state.attempt = discoveryAttemptCancelled
  state.output.errorPath = state.root

proc markFailed(state: var DiscoveryState, path: string) {.inline.} =
  state.attempt = discoveryAttemptFailed
  state.output.errorPath = path

proc addDirectory(state: var DiscoveryState, path: string, stamp: FileStamp): bool =
  if not state.outputDirectories.hasKey(path) and not state.budget.admitDirectory():
    state.attempt = discoveryAttemptLimited
    state.output.errorPath = path
    return false
  state.outputDirectories[path] = stamp
  true

proc addFile(state: var DiscoveryState, path: string): bool =
  if not state.outputFiles.contains(path) and not state.budget.admitFile():
    state.attempt = discoveryAttemptLimited
    state.output.errorPath = path
    return false
  state.outputFiles.incl path
  true

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
    if not state.addDirectory(path, state.currentStamps[path]):
      return false
    inc state.output.directoriesReused
  for path in state.oldFiles:
    if pathWithin(directory, path):
      if not state.addFile(path):
        return false
  true

proc scanDirectory(state: var DiscoveryState, directory: string): bool {.gcsafe.}

proc rebuildSubtree(state: var DiscoveryState, directory: string): bool {.gcsafe.} =
  if state.attempt != discoveryAttemptRunning:
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
  if not state.addDirectory(directory, state.currentStamps[directory]):
    return false
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
  for path in state.oldFiles:
    if parentDir(path) == directory:
      if not state.addFile(path):
        return false
  true

proc scanDirectory(state: var DiscoveryState, directory: string): bool {.gcsafe.} =
  if state.attempt != discoveryAttemptRunning:
    return false
  if shouldCancel(state.cancellation):
    state.markCancelled()
    return false
  let before = fileStamp(directory)
  if not usableStamp(before):
    state.markFailed(directory)
    return false
  if not state.addDirectory(directory, before):
    return false
  inc state.output.directoriesVisited
  try:
    for kind, rawPath in walkDir(directory):
      if shouldCancel(state.cancellation):
        state.markCancelled()
        return false
      if not state.budget.admitEntry():
        state.attempt = discoveryAttemptLimited
        state.output.errorPath = directory
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
          if not state.addFile(path):
            return false
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
    state.attempt = discoveryAttemptUnstable
    return false
  state.outputDirectories[directory] = after
  true

proc finish(state: DiscoveryState): DiscoveryResult {.gcsafe.} =
  result = state.output
  if state.attempt == discoveryAttemptCancelled:
    result.status = discoveryCancelled
    result.paths.setLen(0)
    result.directories.setLen(0)
    return
  if state.attempt != discoveryAttemptRunning:
    result.status = discoveryFailed
    result.paths.setLen(0)
    result.directories.setLen(0)
    return
  var paths = newSeqOfCap[string](state.outputFiles.len)
  for path in state.outputFiles:
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
    root: string, cancellation: DiscoveryCancellation, budget: DiscoveryBudget
): DiscoveryState {.gcsafe.} =
  result.root = root
  result.cancellation = cancellation
  result.oldDirectories = initTable[string, ManifestDirectory]()
  result.oldFiles = initHashSet[string]()
  result.currentStamps = initTable[string, FileStamp]()
  result.outputDirectories = initTable[string, FileStamp]()
  result.outputFiles = initHashSet[string]()
  result.budget = budget
  result.attempt = discoveryAttemptRunning
  result.output.errorPath = root

proc fullDiscovery(
    root: string, cancellation: DiscoveryCancellation, budget: DiscoveryBudget
): tuple[value: DiscoveryResult, budget: DiscoveryBudget] {.gcsafe.} =
  for _ in 0 .. 1:
    var state = initState(root, cancellation, budget)
    if state.scanDirectory(root):
      result.value = state.finish()
      result.budget = state.budget
      return
    if state.attempt == discoveryAttemptCancelled:
      result.value = state.finish()
      result.budget = state.budget
      return
    if state.attempt != discoveryAttemptUnstable:
      result.value = state.finish()
      result.budget = state.budget
      return
  result.value.status = discoveryFailed
  result.value.errorPath = root
  result.budget = budget

proc appendNimbleSources(
    root: string,
    result: var DiscoveryResult,
    budget: var DiscoveryBudget,
    cancellation: DiscoveryCancellation,
) =
  if result.status != discoveryComplete:
    return
  let dependencies = nimbleDependencySourcesBounded(root, budget, cancellation)
  if dependencies.cancelled:
    result.status = discoveryCancelled
    result.errorPath = root
    result.paths.setLen(0)
    result.directories.setLen(0)
    return
  if dependencies.limited:
    result.status = discoveryFailed
    result.errorPath = root
    result.paths.setLen(0)
    result.directories.setLen(0)
    return
  for path in dependencies.paths:
    var present = false
    for existing in result.paths:
      if existing == path:
        present = true
        break
    if not present:
      result.paths.add path
  result.paths.sort

proc prepareWarmState(
    root: string,
    previous: ProjectManifest,
    cancellation: DiscoveryCancellation,
    budget: DiscoveryBudget,
): tuple[available: bool, state: DiscoveryState] {.gcsafe.} =
  result.state = initState(root, cancellation, budget)
  if not previous.discoveryValid or previous.root != root or
      previous.directories.len == 0:
    return
  if previous.directories.len > int(budget.capacity) or
      previous.entries.len > int(budget.capacity):
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
        not nimSourcePath(path) or path in result.state.oldFiles:
      return
    result.state.oldFiles.incl path
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
    root: string,
    previous: ProjectManifest,
    cancellation: DiscoveryCancellation,
    budget: DiscoveryBudget,
): tuple[available: bool, value: DiscoveryResult, budget: DiscoveryBudget] {.gcsafe.} =
  let prepared = prepareWarmState(root, previous, cancellation, budget)
  if not prepared.available:
    return
  if prepared.state.attempt == discoveryAttemptCancelled:
    result.available = true
    result.value = prepared.state.finish()
    result.budget = prepared.state.budget
    return
  var state = prepared.state
  if state.changedDirectories.len == 0:
    if state.restoreSubtree(root):
      result.available = true
      result.value = state.finish()
      result.budget = state.budget
    elif state.attempt in {discoveryAttemptCancelled, discoveryAttemptLimited}:
      result.available = true
      result.value = state.finish()
      result.budget = state.budget
    return
  if state.rebuildSubtree(root):
    result.available = true
    result.value = state.finish()
    result.budget = state.budget
  elif state.attempt in {discoveryAttemptCancelled, discoveryAttemptLimited}:
    result.available = true
    result.value = state.finish()
    result.budget = state.budget

proc discoverSourcesWithBudget(
    root: string,
    previous: ProjectManifest,
    cancellation: DiscoveryCancellation,
    budget: DiscoveryBudget,
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
  let incremental = incrementalDiscovery(canonicalRoot, previous, cancellation, budget)
  if incremental.available:
    result = incremental.value
    if result.status == discoveryComplete:
      var updatedBudget = incremental.budget
      appendNimbleSources(canonicalRoot, result, updatedBudget, cancellation)
    return
  let cold = fullDiscovery(canonicalRoot, cancellation, budget)
  result = cold.value
  if result.status == discoveryComplete:
    var updatedBudget = cold.budget
    appendNimbleSources(canonicalRoot, result, updatedBudget, cancellation)

proc discoverSources*(
    root: string, previous: ProjectManifest, cancellation: DiscoveryCancellation = nil
): DiscoveryResult {.gcsafe.} =
  discoverSourcesWithBudget(root, previous, cancellation, initDiscoveryBudget())

when defined(onimTest):
  proc discoverSourcesWithLimit*(
      root: string,
      previous: ProjectManifest,
      limit: uint32,
      cancellation: DiscoveryCancellation = nil,
  ): DiscoveryResult {.gcsafe.} =
    discoverSourcesWithBudget(root, previous, cancellation, initDiscoveryBudget(limit))

proc discoverSources*(
    root: string, cancellation: DiscoveryCancellation = nil
): DiscoveryResult {.gcsafe.} =
  discoverSources(root, ProjectManifest(), cancellation)
