import std/[algorithm, atomics, json, strutils, tables]
import std/os except FileId
import std/sets

import ../index/cache
import ../index/source_index
import ./ids
import ./module_catalog
import ./paths
import ./source_discovery

type
  BootstrapRequest* = object
    jobGeneration*: uint64
    workspaceGeneration*: uint64
    configGeneration*: uint64
    root*: string

  BootstrapResultKind* = enum
    bootstrapComplete
    bootstrapCancelled
    bootstrapFailed
    bootstrapStopped

  BootstrapFile* = object
    path*: string
    sourceHash*: uint64
    byteLength*: int
    stamp*: FileStamp
    forward*: seq[string]
    unresolved*: bool

  BootstrapResult* = object
    kind*: BootstrapResultKind
    jobGeneration*: uint64
    workspaceGeneration*: uint64
    configGeneration*: uint64
    root*: string
    directories*: seq[ManifestDirectory]
    discoveryValid*: bool
    files*: seq[BootstrapFile]

  ManifestReuseState = enum
    manifestNotReused
    manifestReused

  ManifestReuse = object
    state: ManifestReuseState
    entry: ManifestEntry
    forward: seq[string]

  BootstrapWorkerState = enum
    bootstrapWorkerStopped
    bootstrapWorkerRunning

var bootstrapRequests: Channel[BootstrapRequest]
var bootstrapResults: Channel[string]
var bootstrapThread: Thread[void]
var bootstrapState = bootstrapWorkerStopped
var bootstrapCancelGeneration: Atomic[uint64]
var bootstrapStopRequested: Atomic[bool]

proc traceBootstrapWorker(event: string) {.inline.} =
  if getEnv("ONIM_TRACE_WORKERS").len > 0:
    stderr.writeLine("onim bootstrap worker: " & event)

proc workerInteger(node: JsonNode, name: string): int64 {.gcsafe.} =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JInt:
    node[name].getInt
  else:
    0

proc workerString(node: JsonNode, name: string): string {.gcsafe.} =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JString:
    result = node[name].getStr

proc workerUint32(node: JsonNode, name: string): uint32 {.gcsafe.} =
  let value = workerInteger(node, name)
  if value >= 0 and value <= int64(high(uint32)):
    result = uint32(value)

proc cancellationRequested(jobGeneration: uint64): bool {.gcsafe.} =
  bootstrapStopRequested.load(moRelaxed) or
    bootstrapCancelGeneration.load(moRelaxed) != jobGeneration

proc addUniquePath(paths: var seq[string], path: string) {.gcsafe.} =
  if path.len == 0:
    return
  for existing in paths:
    if existing == path:
      return
  paths.add path

proc stableDiskSource(
    path: string
): tuple[valid: bool, source: string, stamp: FileStamp] {.gcsafe.} =
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

proc oldManifestEntries(
    manifest: ProjectManifest
): Table[string, ManifestEntry] {.gcsafe.} =
  result = initTable[string, ManifestEntry]()
  if not manifest.graphValid:
    return
  for entry in manifest.entries:
    result[canonicalPath(entry.path)] = entry

proc indexDiskSource(
    root, path: string,
    stamp: FileStamp,
    previous: Table[string, ManifestEntry],
    jobGeneration: uint64,
): tuple[valid: bool, index: SourceIndex, stamp: FileStamp] {.gcsafe.} =
  if cancellationRequested(jobGeneration):
    return
  if previous.hasKey(path):
    let entry = previous[path]
    if sameFileStamp(stamp, entry.stamp) and entry.byteLength >= 0 and
        entry.byteLength <= int64(high(int)):
      let cached = loadCachedSourceIndexFingerprint(
        root, path, entry.sourceHash, int(entry.byteLength)
      )
      if cached != nil:
        return (true, cached, stamp)

  let stable = stableDiskSource(path)
  if not stable.valid or cancellationRequested(jobGeneration):
    return
  let indexed = loadCachedSourceIndex(root, path, stable.source)
  if indexed != nil:
    return (true, indexed, stable.stamp)
  let built = indexSource(stable.source)
  if cancellationRequested(jobGeneration):
    return
  discard saveCachedSourceIndex(root, path, stable.source, built)
  (true, built, stable.stamp)

proc reusableManifestFile(
    stamp: FileStamp,
    entry: ManifestEntry,
    previousPaths: openArray[string],
    present: HashSet[string],
): tuple[state: ManifestReuseState, forward: seq[string]] {.gcsafe.} =
  if entry.byteLength < 0 or entry.byteLength > int64(high(int)) or
      stamp.size != entry.byteLength or not sameFileStamp(stamp, entry.stamp):
    return
  var previousOrdinal = high(uint32)
  for dependencyOrdinal in entry.forwardOrdinals:
    if dependencyOrdinal >= uint32(previousPaths.len) or
        (previousOrdinal != high(uint32) and dependencyOrdinal <= previousOrdinal):
      return
    let dependency = previousPaths[int(dependencyOrdinal)]
    if dependency.len == 0 or not present.contains(dependency):
      return
    result.forward.add dependency
    previousOrdinal = dependencyOrdinal
  result.state = manifestReused

proc referenceIsStdlib(reference: string): bool {.gcsafe.} =
  reference == "std" or reference.startsWith("std/")

proc addReferences(
    target: var BootstrapFile,
    references: openArray[string],
    catalog: ModuleCatalog,
    pathsById: openArray[string],
): bool {.gcsafe.} =
  for reference in references:
    let resolution = catalog.resolve(target.path, reference)
    if resolution.kind == moduleResolved:
      let ordinal = int(resolution.id) - 1
      if ordinal >= 0 and ordinal < pathsById.len:
        addUniquePath(target.forward, pathsById[ordinal])
    elif not referenceIsStdlib(reference):
      result = true

proc buildBootstrap(request: BootstrapRequest): BootstrapResult {.gcsafe.} =
  result.kind = bootstrapFailed
  result.jobGeneration = request.jobGeneration
  result.workspaceGeneration = request.workspaceGeneration
  result.configGeneration = request.configGeneration
  result.root = request.root
  if request.root.len == 0 or not dirExists(request.root):
    return
  if cancellationRequested(request.jobGeneration):
    result.kind = bootstrapCancelled
    return

  let generation = request.jobGeneration
  let previousManifest = loadProjectManifest(request.root)
  let discovered = discoverSources(
    request.root,
    previousManifest,
    proc(): bool {.gcsafe.} =
      cancellationRequested(generation),
  )
  case discovered.status
  of discoveryCancelled:
    result.kind = bootstrapCancelled
    return
  of discoveryFailed:
    return
  of discoveryComplete:
    discard
  let paths = discovered.paths

  result.directories = discovered.directories
  result.discoveryValid = true
  var previous = oldManifestEntries(previousManifest)
  var previousPaths: seq[string] = @[]
  if previousManifest.graphValid:
    previousPaths = newSeqOfCap[string](previousManifest.entries.len)
    for entry in previousManifest.entries:
      previousPaths.add entry.path
  var present = initHashSet[string]()
  for path in paths:
    present.incl path

  var indexes = newSeq[SourceIndex](paths.len)
  var stamps = newSeq[FileStamp](paths.len)
  var reused = newSeq[ManifestReuse](paths.len)
  for ordinal, path in paths:
    if cancellationRequested(request.jobGeneration):
      result.kind = bootstrapCancelled
      return
    let stamp = fileStamp(path)
    var reusedFile: tuple[state: ManifestReuseState, forward: seq[string]]
    if previous.hasKey(path):
      reusedFile = reusableManifestFile(stamp, previous[path], previousPaths, present)
    if reusedFile.state == manifestReused:
      reused[ordinal] = ManifestReuse(
        state: manifestReused, entry: previous[path], forward: reusedFile.forward
      )
      stamps[ordinal] = stamp
      continue
    let indexed =
      indexDiskSource(request.root, path, stamp, previous, request.jobGeneration)
    if not indexed.valid:
      if cancellationRequested(request.jobGeneration):
        result.kind = bootstrapCancelled
      return
    indexes[ordinal] = indexed.index
    stamps[ordinal] = indexed.stamp

  if cancellationRequested(request.jobGeneration):
    result.kind = bootstrapCancelled
    return

  var moduleFiles = newSeqOfCap[ModuleFile](paths.len)
  for ordinal, path in paths:
    moduleFiles.add ModuleFile(id: FileId(ordinal + 1), path: path)
  let catalog = buildModuleCatalog(request.root, moduleFiles)

  result.files = newSeqOfCap[BootstrapFile](paths.len)
  for ordinal, path in paths:
    if cancellationRequested(request.jobGeneration):
      result.kind = bootstrapCancelled
      result.files.setLen(0)
      return
    var file: BootstrapFile
    if reused[ordinal].state == manifestReused:
      let reusedFile = reused[ordinal]
      file = BootstrapFile(
        path: path,
        sourceHash: reusedFile.entry.sourceHash,
        byteLength: int(reusedFile.entry.byteLength),
        stamp: stamps[ordinal],
        forward: reusedFile.forward,
        unresolved: reusedFile.entry.unresolved,
      )
    else:
      let index = indexes[ordinal]
      if index == nil:
        return
      file = BootstrapFile(
        path: path,
        sourceHash: index.contentHash,
        byteLength: index.byteLength,
        stamp: stamps[ordinal],
      )
      file.unresolved = file.addReferences(index.imports, catalog, paths)
      if index.includes.len > 0:
        file.unresolved =
          file.unresolved or file.addReferences(index.includes, catalog, paths)
      file.forward.sort
    result.files.add file

  result.kind = bootstrapComplete

proc encodeBootstrapResult*(value: BootstrapResult): string =
  var node = newJObject()
  node["kind"] = %"bootstrap"
  node["status"] = %ord(value.kind)
  node["jobGeneration"] = %value.jobGeneration
  node["workspaceGeneration"] = %value.workspaceGeneration
  node["configGeneration"] = %value.configGeneration
  node["root"] = %value.root
  node["discoveryValid"] = %value.discoveryValid
  var directories = newJArray()
  for directory in value.directories:
    directories.add %*{
      "path": directory.path,
      "stamp": {
        "size": directory.stamp.size,
        "modifiedSeconds": directory.stamp.modifiedSeconds,
        "modifiedNanoseconds": directory.stamp.modifiedNanoseconds,
      },
    }
  node["directories"] = directories
  var files = newJArray()
  for file in value.files:
    var forward = newJArray()
    for path in file.forward:
      forward.add %path
    files.add %*{
      "path": file.path,
      "sourceHashHigh": uint32(file.sourceHash shr 32),
      "sourceHashLow": uint32(file.sourceHash and uint64(high(uint32))),
      "byteLength": file.byteLength,
      "stamp": {
        "size": file.stamp.size,
        "modifiedSeconds": file.stamp.modifiedSeconds,
        "modifiedNanoseconds": file.stamp.modifiedNanoseconds,
      },
      "forward": forward,
      "unresolved": file.unresolved,
    }
  node["files"] = files
  $node

proc decodeBootstrapResult*(line: string): BootstrapResult =
  result.kind = bootstrapFailed
  try:
    let node = parseJson(line)
    if node.kind != JObject or not node.hasKey("kind") or
        workerString(node, "kind") != "bootstrap":
      return
    let status = workerInteger(node, "status")
    if status < 0 or status > ord(high(BootstrapResultKind)):
      return
    result.kind = BootstrapResultKind(status)
    result.jobGeneration = uint64(max(workerInteger(node, "jobGeneration"), 0))
    result.workspaceGeneration =
      uint64(max(workerInteger(node, "workspaceGeneration"), 0))
    result.configGeneration = uint64(max(workerInteger(node, "configGeneration"), 0))
    result.root = workerString(node, "root")
    result.discoveryValid =
      node.hasKey("discoveryValid") and node["discoveryValid"].kind == JBool and
      node["discoveryValid"].getBool
    if node.hasKey("directories"):
      if node["directories"].kind != JArray:
        return
      for item in node["directories"].items:
        if item.kind != JObject or not item.hasKey("stamp") or
            item["stamp"].kind != JObject:
          result.kind = bootstrapFailed
          return
        var directory = ManifestDirectory(path: workerString(item, "path"))
        directory.stamp.size = workerInteger(item["stamp"], "size")
        directory.stamp.modifiedSeconds =
          workerInteger(item["stamp"], "modifiedSeconds")
        directory.stamp.modifiedNanoseconds =
          int32(workerInteger(item["stamp"], "modifiedNanoseconds"))
        result.directories.add directory
    elif result.discoveryValid:
      result.kind = bootstrapFailed
      return
    if not node.hasKey("files") or node["files"].kind != JArray:
      return
    for item in node["files"].items:
      if item.kind != JObject or not item.hasKey("stamp") or
          item["stamp"].kind != JObject:
        result.kind = bootstrapFailed
        result.files.setLen(0)
        return
      var file = BootstrapFile(
        path: workerString(item, "path"),
        sourceHash:
          (uint64(workerUint32(item, "sourceHashHigh")) shl 32) or
          uint64(workerUint32(item, "sourceHashLow")),
        byteLength: int(max(workerInteger(item, "byteLength"), -1)),
        unresolved:
          item.hasKey("unresolved") and item["unresolved"].kind == JBool and
          item["unresolved"].getBool,
      )
      file.stamp.size = workerInteger(item["stamp"], "size")
      file.stamp.modifiedSeconds = workerInteger(item["stamp"], "modifiedSeconds")
      file.stamp.modifiedNanoseconds =
        int32(workerInteger(item["stamp"], "modifiedNanoseconds"))
      if item.hasKey("forward") and item["forward"].kind == JArray:
        for path in item["forward"].items:
          if path.kind == JString:
            file.forward.add path.getStr
      result.files.add file
  except CatchableError:
    result.kind = bootstrapFailed
    result.files.setLen(0)

proc bootstrapLoop() {.thread.} =
  while true:
    let request = bootstrapRequests.recv()
    if request.root.len == 0 and request.jobGeneration == high(uint64):
      break
    let value = buildBootstrap(request)
    if getEnv("ONIM_TRACE_WORKERS").len > 0:
      stderr.writeLine(
        "onim bootstrap worker: result=" & $value.kind & " files=" & $value.files.len
      )
    bootstrapResults.send(encodeBootstrapResult(value))
    if bootstrapStopRequested.load(moRelaxed):
      break
  bootstrapResults.send(encodeBootstrapResult(BootstrapResult(kind: bootstrapStopped)))

proc startBootstrapWorker*(): bool =
  if bootstrapState == bootstrapWorkerRunning:
    return true
  var requestsOpened = false
  var resultsOpened = false
  try:
    bootstrapRequests.open(1)
    requestsOpened = true
    bootstrapResults.open()
    resultsOpened = true
    bootstrapCancelGeneration.store(0'u64)
    bootstrapStopRequested.store(false)
    createThread(bootstrapThread, bootstrapLoop)
    bootstrapState = bootstrapWorkerRunning
    traceBootstrapWorker("start")
    true
  except CatchableError:
    if requestsOpened:
      bootstrapRequests.close()
      bootstrapRequests = default(Channel[BootstrapRequest])
    if resultsOpened:
      bootstrapResults.close()
      bootstrapResults = default(Channel[string])
    bootstrapState = bootstrapWorkerStopped
    false

proc submitBootstrap*(request: BootstrapRequest): bool =
  if bootstrapState != bootstrapWorkerRunning:
    return false
  bootstrapCancelGeneration.store(request.jobGeneration)
  bootstrapRequests.send(request)
  true

proc cancelBootstrap*(jobGeneration: uint64) =
  if bootstrapState == bootstrapWorkerRunning:
    traceBootstrapWorker("cancel")
    bootstrapCancelGeneration.store(jobGeneration)

proc tryReceiveBootstrap*(value: var BootstrapResult): bool =
  if bootstrapState != bootstrapWorkerRunning:
    return false
  let received = bootstrapResults.tryRecv()
  if not received.dataAvailable:
    return false
  value = decodeBootstrapResult(received.msg)
  true

proc receiveBootstrap*(): BootstrapResult =
  if bootstrapState != bootstrapWorkerRunning:
    result.kind = bootstrapStopped
    return
  result = decodeBootstrapResult(bootstrapResults.recv())

proc stopBootstrapWorker*() =
  if bootstrapState != bootstrapWorkerRunning:
    return
  bootstrapStopRequested.store(true)
  bootstrapCancelGeneration.store(high(uint64))
  bootstrapRequests.send(BootstrapRequest(jobGeneration: high(uint64), root: ""))
  bootstrapThread.joinThread()
  bootstrapRequests.close()
  bootstrapResults.close()
  bootstrapRequests = default(Channel[BootstrapRequest])
  bootstrapResults = default(Channel[string])
  bootstrapState = bootstrapWorkerStopped
  traceBootstrapWorker("reap")
