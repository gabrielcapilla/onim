import std/[algorithm, os, sets, streams, times]

import ../syntax/imports
import ../syntax/tokens
import ../syntax/parser
import ./source_index
import ./occurrences
import ./scopes
import ./symbols
import ./types
import ./cache_wire
import ./cache_source_index
import ../session/paths

const
  cacheMagic = "ONIMIDX1"
  manifestMagic = "ONIMMAN1"
  cacheVersion = 7'u32
  manifestVersion = 3'u32
  manifestGraphVersion = 5'u32
  manifestDiscoveryVersion = 1'u32
  cacheEndian = 1'u8
  maxCacheBytes = 64 * 1024 * 1024

type
  FileStamp* = object
    size*: int64
    modifiedSeconds*: int64
    modifiedNanoseconds*: int32

  ManifestEntry* = object
    path*: string
    sourceHash*: uint64
    byteLength*: int64
    stamp*: FileStamp
    forwardOrdinals*: seq[uint32]
    unresolved*: bool

  ManifestDirectory* = object
    path*: string
    stamp*: FileStamp

  ProjectManifest* = object
    root*: string
    entries*: seq[ManifestEntry]
    graphValid*: bool
    directories*: seq[ManifestDirectory]
    discoveryValid*: bool

proc writeStamp(stream: Stream, stamp: FileStamp) =
  stream.write(stamp.size)
  stream.write(stamp.modifiedSeconds)
  stream.write(stamp.modifiedNanoseconds)

proc readStamp(stream: Stream): FileStamp =
  result.size = stream.readInt64()
  result.modifiedSeconds = stream.readInt64()
  result.modifiedNanoseconds = stream.readInt32()

proc validStamp(stamp: FileStamp): bool {.inline.} =
  stamp.size >= -1 and stamp.modifiedNanoseconds >= -1 and
    stamp.modifiedNanoseconds < 1_000_000_000

proc usableStamp*(stamp: FileStamp): bool {.inline.} =
  stamp.size >= 0 and stamp.modifiedSeconds >= 0 and stamp.modifiedNanoseconds >= 0

proc cacheBaseDirectory(): string =
  let configured = getEnv("ONIM_CACHE_DIR")
  if configured.len > 0:
    return canonicalPath(configured)
  let xdg = getEnv("XDG_CACHE_HOME")
  if xdg.len > 0:
    return canonicalPath(xdg / "onim")
  canonicalPath(getHomeDir() / ".cache" / "onim")

proc projectKey(projectRoot: string): string =
  $contentFingerprint(canonicalPath(projectRoot))

proc projectCacheDirectory*(projectRoot: string): string =
  let root = canonicalPath(projectRoot)
  if root.len == 0:
    return ""
  cacheBaseDirectory() / "v1" / projectKey(root) / "modules"

proc cacheFilePath*(projectRoot, modulePath: string): string =
  let root = canonicalPath(projectRoot)
  let module = canonicalPath(modulePath)
  if root.len == 0 or module.len == 0:
    return ""
  projectCacheDirectory(root) / ($contentFingerprint(module) & ".idx")

proc projectManifestPath*(projectRoot: string): string =
  let modules = projectCacheDirectory(projectRoot)
  if modules.len == 0:
    return ""
  splitFile(modules).dir / "manifest"

proc temporaryCachePath(path: string): string =
  path & ".tmp." & $getCurrentProcessId() & "." & $epochTime()

proc fileStamp*(path: string): FileStamp {.gcsafe.} =
  try:
    let info = getFileInfo(path)
    result.size = int64(info.size)
    result.modifiedSeconds = info.lastWriteTime.toUnix
    result.modifiedNanoseconds = int32(info.lastWriteTime.nanosecond)
  except CatchableError:
    result.size = -1
    result.modifiedSeconds = -1
    result.modifiedNanoseconds = -1

proc sameFileStamp*(left, right: FileStamp): bool {.gcsafe.} =
  left.size == right.size and left.modifiedSeconds == right.modifiedSeconds and
    left.modifiedNanoseconds == right.modifiedNanoseconds

proc writeManifestPayload(
    stream: Stream,
    entries: openArray[ManifestEntry],
    graphValid: bool,
    directories: openArray[ManifestDirectory],
    discoveryValid: bool,
) =
  stream.write(manifestGraphVersion)
  writeFlag(stream, graphValid)
  stream.write(manifestDiscoveryVersion)
  writeFlag(stream, discoveryValid)
  writeCount(stream, directories.len, maxRecordCount)
  for directory in directories:
    writeString(stream, canonicalPath(directory.path))
    writeStamp(stream, directory.stamp)
  writeCount(stream, entries.len, maxRecordCount)
  for entry in entries:
    writeString(stream, canonicalPath(entry.path))
    stream.write(entry.sourceHash)
    stream.write(entry.byteLength)
    writeStamp(stream, entry.stamp)
    writeCount(stream, entry.forwardOrdinals.len, maxRecordCount)
    for ordinal in entry.forwardOrdinals:
      stream.write(ordinal)
    writeFlag(stream, entry.unresolved)

proc readManifestPayload(stream: Stream, root: string): ProjectManifest =
  result.root = root
  if stream.readUint32() != manifestGraphVersion:
    invalidCache("manifest graph version does not match")
  result.graphValid = readFlag(stream)
  if stream.readUint32() != manifestDiscoveryVersion:
    invalidCache("manifest discovery version does not match")
  result.discoveryValid = readFlag(stream)
  let directoryCount = readCount(stream, maxRecordCount)
  result.directories = newSeqOfCap[ManifestDirectory](directoryCount)
  var directoryPaths = initHashSet[string]()
  var previousDirectoryPath = ""
  for _ in 0 ..< directoryCount:
    let path = canonicalPath(readString(stream))
    let stamp = readStamp(stream)
    if path.len == 0 or not pathWithin(root, path) or path in directoryPaths or
        (previousDirectoryPath.len > 0 and path <= previousDirectoryPath) or
        not validStamp(stamp):
      invalidCache("manifest directory is invalid or duplicated")
    directoryPaths.incl path
    previousDirectoryPath = path
    result.directories.add ManifestDirectory(path: path, stamp: stamp)
  if result.discoveryValid and
      (result.directories.len == 0 or not directoryPaths.contains(root)):
    invalidCache("manifest discovery is empty")
  let count = readCount(stream, maxRecordCount)
  result.entries = newSeqOfCap[ManifestEntry](count)
  var paths = initHashSet[string]()
  var previousEntryPath = ""
  for _ in 0 ..< count:
    let path = canonicalPath(readString(stream))
    if path.len == 0 or not pathWithin(root, path) or path in paths or
        (previousEntryPath.len > 0 and path <= previousEntryPath):
      invalidCache("manifest path is invalid or duplicated")
    paths.incl path
    previousEntryPath = path
    var entry = ManifestEntry(path: path)
    entry.sourceHash = stream.readUint64()
    entry.byteLength = stream.readInt64()
    entry.stamp = readStamp(stream)
    if entry.byteLength < 0 or not validStamp(entry.stamp):
      invalidCache("manifest file stamp is invalid")
    let forwardCount = readCount(stream, maxRecordCount)
    entry.forwardOrdinals = newSeqOfCap[uint32](forwardCount)
    var previousOrdinal = uint32(0)
    for _ in 0 ..< forwardCount:
      let ordinal = stream.readUint32()
      if ordinal >= uint32(count) or
          (entry.forwardOrdinals.len > 0 and ordinal <= previousOrdinal):
        invalidCache("manifest graph row is invalid")
      previousOrdinal = ordinal
      entry.forwardOrdinals.add ordinal
    entry.unresolved = readFlag(stream)
    result.entries.add entry

proc readManifestEnvelope(stream: Stream, projectRoot: string): ProjectManifest =
  if stream.readStr(manifestMagic.len) != manifestMagic:
    invalidCache("manifest magic does not match")
  if stream.readUint32() != manifestVersion or stream.readUint8() != cacheEndian:
    invalidCache("manifest version does not match")
  let storedRoot = readString(stream)
  let root = canonicalPath(projectRoot)
  if storedRoot != root:
    invalidCache("manifest identity does not match")
  let payloadLength = stream.readUint64()
  if payloadLength > uint64(maxCacheBytes):
    invalidCache("manifest payload is out of bounds")
  let payloadHash = stream.readUint64()
  let payload = stream.readStr(int(payloadLength))
  if payload.len != int(payloadLength) or contentFingerprint(payload) != payloadHash:
    invalidCache("manifest checksum does not match")
  if not stream.atEnd:
    invalidCache("manifest contains trailing data")
  let payloadStream = newStringStream(payload)
  result = readManifestPayload(payloadStream, root)
  if not payloadStream.atEnd:
    invalidCache("manifest payload contains trailing data")

proc loadProjectManifest*(projectRoot: string): ProjectManifest {.gcsafe.} =
  result.root = canonicalPath(projectRoot)
  let path = projectManifestPath(projectRoot)
  if path.len == 0 or not fileExists(path):
    return
  var stream: FileStream
  try:
    stream = newFileStream(path, fmRead)
    if stream == nil:
      return
    result = readManifestEnvelope(stream, projectRoot)
  except CatchableError:
    result = ProjectManifest(root: canonicalPath(projectRoot))
  finally:
    if stream != nil:
      try:
        stream.close()
      except CatchableError:
        discard

proc saveProjectManifestWithDiscovery*(
    projectRoot: string,
    entries: openArray[ManifestEntry],
    graphValid: bool,
    directories: openArray[ManifestDirectory],
    discoveryValid: bool,
): bool =
  let root = canonicalPath(projectRoot)
  if root.len == 0:
    return false

  var orderedDirectories: seq[ManifestDirectory] = @[]
  if discoveryValid:
    for directory in directories:
      let path = canonicalPath(directory.path)
      if path.len == 0 or not pathWithin(root, path) or not usableStamp(directory.stamp):
        return false
      orderedDirectories.add ManifestDirectory(path: path, stamp: directory.stamp)
    orderedDirectories.sort(
      proc(left, right: ManifestDirectory): int =
        cmp(left.path, right.path)
    )
    for index in 1 ..< orderedDirectories.len:
      if orderedDirectories[index - 1].path == orderedDirectories[index].path:
        return false
    if orderedDirectories.len == 0 or orderedDirectories[0].path != root:
      return false

  var ordered: seq[ManifestEntry] = @[]
  for entry in entries:
    if entry.path.len == 0 or entry.byteLength < 0:
      return false
    var copied = entry
    copied.path = canonicalPath(entry.path)
    if not pathWithin(root, copied.path):
      return false
    for index, ordinal in copied.forwardOrdinals:
      if ordinal >= uint32(entries.len) or
          (index > 0 and ordinal <= copied.forwardOrdinals[index - 1]):
        return false
    if not graphValid:
      copied.forwardOrdinals.setLen(0)
      copied.unresolved = false
    ordered.add copied
  ordered.sort(
    proc(left, right: ManifestEntry): int =
      cmp(left.path, right.path)
  )
  for index in 1 ..< ordered.len:
    if ordered[index - 1].path == ordered[index].path:
      return false

  let path = projectManifestPath(root)
  let directory = splitFile(path).dir
  let temporary = temporaryCachePath(path)
  var payloadStream = newStringStream()
  var stream: FileStream
  try:
    writeManifestPayload(
      payloadStream, ordered, graphValid, orderedDirectories, discoveryValid
    )
    payloadStream.flush()
    let payload = payloadStream.data
    if payload.len > maxCacheBytes:
      return false
    createDir(directory)
    stream = newFileStream(temporary, fmWrite)
    if stream == nil:
      return false
    stream.write(manifestMagic)
    stream.write(manifestVersion)
    stream.write(cacheEndian)
    writeString(stream, root)
    stream.write(uint64(payload.len))
    stream.write(contentFingerprint(payload))
    if payload.len > 0:
      stream.write(payload)
    stream.flush()
    stream.close()
    stream = nil
    moveFile(temporary, path)
    result = true
  except CatchableError:
    result = false
  finally:
    if stream != nil:
      try:
        stream.close()
      except CatchableError:
        discard

    if not result and fileExists(temporary):
      try:
        removeFile(temporary)
      except CatchableError:
        discard

proc saveProjectManifest*(
    projectRoot: string, entries: openArray[ManifestEntry], graphValid = false
): bool =
  let directories: seq[ManifestDirectory] = @[]
  saveProjectManifestWithDiscovery(projectRoot, entries, graphValid, directories, false)

proc encodeSourceIndex(index: SourceIndex): string =
  let payload = newStringStream()
  writeSourceIndex(payload, index)
  payload.flush()
  payload.data

proc writeEnvelope(
    stream: Stream, projectRoot, modulePath, source: string, payload: string
) =
  stream.write(cacheMagic)
  stream.write(cacheVersion)
  stream.write(cacheEndian)
  writeString(stream, canonicalPath(projectRoot))
  writeString(stream, canonicalPath(modulePath))
  stream.write(contentFingerprint(source))
  stream.write(uint64(source.len))
  stream.write(uint64(payload.len))
  stream.write(contentFingerprint(payload))
  if payload.len > 0:
    stream.write(payload)

proc readEnvelope(
    stream: Stream,
    projectRoot, modulePath: string,
    expectedHash: uint64,
    expectedLength: int,
): SourceIndex =
  if stream.readStr(cacheMagic.len) != cacheMagic:
    invalidCache("cache magic does not match")
  if stream.readUint32() != cacheVersion or stream.readUint8() != cacheEndian:
    invalidCache("cache version does not match")
  let storedRoot = readString(stream)
  let storedModule = readString(stream)
  let root = canonicalPath(projectRoot)
  let module = canonicalPath(modulePath)
  if storedRoot != root or storedModule != module:
    invalidCache("cache identity does not match")

  let sourceHash = stream.readUint64()
  let sourceLength = stream.readUint64()
  if expectedLength < 0 or sourceHash != expectedHash or
      sourceLength != uint64(expectedLength):
    invalidCache("cache source does not match")

  let payloadLength = stream.readUint64()
  if payloadLength > uint64(maxCacheBytes):
    invalidCache("cache payload is out of bounds")
  let payloadHash = stream.readUint64()
  let payload = stream.readStr(int(payloadLength))
  if payload.len != int(payloadLength) or contentFingerprint(payload) != payloadHash:
    invalidCache("cache payload checksum does not match")
  if not stream.atEnd:
    invalidCache("cache contains trailing data")
  let payloadStream = newStringStream(payload)
  result = readSourceIndex(payloadStream, expectedHash, expectedLength)
  if not payloadStream.atEnd:
    invalidCache("cache payload contains trailing data")

proc loadCachedSourceIndexFingerprint*(
  projectRoot, modulePath: string, sourceHash: uint64, byteLength: int
): SourceIndex {.gcsafe.}

proc loadCachedSourceIndex*(
    projectRoot, modulePath, source: string
): SourceIndex {.gcsafe.} =
  result = loadCachedSourceIndexFingerprint(
    projectRoot, modulePath, contentFingerprint(source), source.len
  )

proc loadCachedSourceIndexFingerprint*(
    projectRoot, modulePath: string, sourceHash: uint64, byteLength: int
): SourceIndex {.gcsafe.} =
  let path = cacheFilePath(projectRoot, modulePath)
  if path.len == 0 or not fileExists(path):
    return
  var stream: FileStream
  try:
    stream = newFileStream(path, fmRead)
    if stream == nil:
      return
    result = readEnvelope(stream, projectRoot, modulePath, sourceHash, byteLength)
  except CatchableError:
    result = nil
  finally:
    if stream != nil:
      try:
        stream.close()
      except CatchableError:
        discard

proc saveCachedSourceIndex*(
    projectRoot, modulePath, source: string, index: SourceIndex
): bool {.gcsafe.} =
  if projectRoot.len == 0 or modulePath.len == 0 or index == nil or
      index.contentHash != contentFingerprint(source) or index.byteLength != source.len:
    return false
  let path = cacheFilePath(projectRoot, modulePath)
  if path.len == 0:
    return false
  let directory = splitFile(path).dir
  let temporary = temporaryCachePath(path)
  var stream: FileStream
  try:
    createDir(directory)
    let payload = encodeSourceIndex(index)
    if payload.len > maxCacheBytes:
      return false
    stream = newFileStream(temporary, fmWrite)
    if stream == nil:
      return false
    writeEnvelope(stream, projectRoot, modulePath, source, payload)
    stream.flush()
    stream.close()
    stream = nil
    moveFile(temporary, path)
    result = true
  except CatchableError:
    result = false
  finally:
    if stream != nil:
      try:
        stream.close()
      except CatchableError:
        discard
    if not result and fileExists(temporary):
      try:
        removeFile(temporary)
      except CatchableError:
        discard
