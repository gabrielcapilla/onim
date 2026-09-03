import std/[algorithm, os, sets, streams, times]

import ../syntax/imports
import ../syntax/lexer
import ./source_index
import ./occurrences
import ./scopes
import ./symbols
import ../session/paths

const
  cacheMagic = "ONIMIDX1"
  manifestMagic = "ONIMMAN1"
  cacheVersion = 2'u32
  manifestVersion = 2'u32
  manifestGraphVersion = 2'u32
  cacheEndian = 1'u8
  maxCacheBytes = 64 * 1024 * 1024
  maxStringBytes = 4 * 1024 * 1024
  maxRecordCount = 1_000_000

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

  ProjectManifest* = object
    root*: string
    entries*: seq[ManifestEntry]
    graphValid*: bool

proc invalidCache(message: string) {.noreturn.} =
  raise newException(IOError, message)

proc writeCount(stream: Stream, count, maximum: int) =
  if count < 0 or count > maximum:
    invalidCache("cache count is out of bounds")
  stream.write(uint32(count))

proc readCount(stream: Stream, maximum: int): int =
  let count = stream.readUint32()
  if count > uint32(maximum):
    invalidCache("cache count is out of bounds")
  int(count)

proc writeString(stream: Stream, value: string) =
  if value.len > maxStringBytes:
    invalidCache("cache string is out of bounds")
  stream.write(uint32(value.len))
  if value.len > 0:
    stream.write(value)

proc readString(stream: Stream): string =
  let length = stream.readUint32()
  if length > uint32(maxStringBytes):
    invalidCache("cache string is out of bounds")
  if length > 0:
    result = stream.readStr(int(length))

proc writeInt(stream: Stream, value: int) =
  stream.write(int64(value))

proc readInt(stream: Stream): int =
  let value = stream.readInt64()
  if value < int64(low(int)) or value > int64(high(int)):
    invalidCache("cache integer is out of bounds")
  int(value)

proc writeFlag(stream: Stream, value: bool) =
  stream.write(if value: 1'u8 else: 0'u8)

proc readFlag(stream: Stream): bool =
  let value = stream.readUint8()
  if value > 1'u8:
    invalidCache("cache flag is invalid")
  value == 1'u8

proc sortedValues(values: HashSet[string]): seq[string] =
  result = newSeqOfCap[string](values.len)
  for value in values:
    result.add value
  result.sort

proc writeStrings(stream: Stream, values: seq[string]) =
  writeCount(stream, values.len, maxRecordCount)
  for value in values:
    writeString(stream, value)

proc readStrings(stream: Stream): seq[string] =
  let count = readCount(stream, maxRecordCount)
  result = newSeqOfCap[string](count)
  for _ in 0 ..< count:
    result.add readString(stream)

proc writeStringSet(stream: Stream, values: HashSet[string]) =
  writeStrings(stream, sortedValues(values))

proc readStringSet(stream: Stream): HashSet[string] =
  result = initHashSet[string]()
  let values = readStrings(stream)
  for value in values:
    result.incl value

proc writeToken(stream: Stream, token: Token) =
  stream.write(uint8(ord(token.kind)))
  writeString(stream, token.text)
  writeInt(stream, token.startOffset)
  writeInt(stream, token.endOffset)
  writeInt(stream, token.line)
  writeInt(stream, token.column)

proc readToken(stream: Stream): Token =
  let kind = stream.readUint8()
  if kind > uint8(ord(high(TokenKind))):
    invalidCache("cache token kind is invalid")
  result.kind = TokenKind(kind)
  result.text = readString(stream)
  result.startOffset = readInt(stream)
  result.endOffset = readInt(stream)
  result.line = readInt(stream)
  result.column = readInt(stream)
  if result.kind == tkIdentifier and not isStropped(result):
    result.keyword = keywordId(result.text)

proc writeImportSymbol(stream: Stream, symbol: ImportSymbol) =
  writeString(stream, symbol.name)
  writeInt(stream, symbol.startOffset)
  writeInt(stream, symbol.endOffset)

proc readImportSymbol(stream: Stream): ImportSymbol =
  result.name = readString(stream)
  result.startOffset = readInt(stream)
  result.endOffset = readInt(stream)

proc writeSourceSymbol(stream: Stream, symbol: SourceSymbol) =
  stream.write(uint8(ord(symbol.kind)))
  stream.write(symbol.nameToken)
  writeFlag(stream, symbol.exported)

proc readSourceSymbol(stream: Stream): SourceSymbol =
  let kind = stream.readUint8()
  if kind > uint8(ord(high(SourceSymbolKind))):
    invalidCache("cache source symbol kind is invalid")
  result.kind = SourceSymbolKind(kind)
  result.nameToken = stream.readUint32()
  result.exported = readFlag(stream)

proc writeImport(stream: Stream, item: ImportInfo) =
  stream.write(uint8(ord(item.form)))
  writeString(stream, item.module)
  writeString(stream, item.alias)
  writeStringSet(stream, item.imported)
  writeStringSet(stream, item.excluded)
  writeCount(stream, item.importedSymbols.len, maxRecordCount)
  for symbol in item.importedSymbols:
    writeImportSymbol(stream, symbol)

  for offset in [
    item.startOffset, item.endOffset, item.moduleStartOffset, item.moduleEndOffset,
    item.diagnosticNameStartOffset, item.diagnosticNameEndOffset, item.itemStartOffset,
    item.itemEndOffset, item.separatorStartOffset, item.line,
  ]:
    writeInt(stream, offset)
  writeString(stream, item.indent)
  writeFlag(stream, item.synthetic)
  writeFlag(stream, item.conditional)
  writeFlag(stream, item.keep)

proc readImport(stream: Stream): ImportInfo =
  let form = stream.readUint8()
  if form > uint8(ord(high(ImportForm))):
    invalidCache("cache import form is invalid")
  result.form = ImportForm(form)
  result.module = readString(stream)
  result.alias = readString(stream)
  result.imported = readStringSet(stream)
  result.excluded = readStringSet(stream)

  let symbolCount = readCount(stream, maxRecordCount)
  result.importedSymbols = newSeqOfCap[ImportSymbol](symbolCount)
  for _ in 0 ..< symbolCount:
    result.importedSymbols.add readImportSymbol(stream)

  result.startOffset = readInt(stream)
  result.endOffset = readInt(stream)
  result.moduleStartOffset = readInt(stream)
  result.moduleEndOffset = readInt(stream)
  result.diagnosticNameStartOffset = readInt(stream)
  result.diagnosticNameEndOffset = readInt(stream)
  result.itemStartOffset = readInt(stream)
  result.itemEndOffset = readInt(stream)
  result.separatorStartOffset = readInt(stream)
  result.line = readInt(stream)
  result.indent = readString(stream)
  result.synthetic = readFlag(stream)
  result.conditional = readFlag(stream)
  result.keep = readFlag(stream)

proc validSpan(startOffset, endOffset, sourceLength: int): bool =
  startOffset >= 0 and endOffset >= startOffset and endOffset <= sourceLength

proc validateToken(token: Token, sourceLength: int) =
  if not validSpan(token.startOffset, token.endOffset, sourceLength) or token.line < 0 or
      token.column < 0:
    invalidCache("cache token range is invalid")

proc validateImport(item: ImportInfo, sourceLength: int) =
  if not validSpan(item.startOffset, item.endOffset, sourceLength) or
      not validSpan(item.moduleStartOffset, item.moduleEndOffset, sourceLength) or
      not validSpan(
        item.diagnosticNameStartOffset, item.diagnosticNameEndOffset, sourceLength
      ) or not validSpan(item.itemStartOffset, item.itemEndOffset, sourceLength) or
      item.line < 0:
    invalidCache("cache import range is invalid")
  if item.separatorStartOffset < -1 or item.separatorStartOffset > sourceLength:
    invalidCache("cache import separator is invalid")
  for symbol in item.importedSymbols:
    if not validSpan(symbol.startOffset, symbol.endOffset, sourceLength):
      invalidCache("cache imported-symbol range is invalid")

proc validateSourceSymbol(
    symbol: SourceSymbol, tokens: seq[Token], previousToken: uint32
) =
  if symbol.nameToken >= uint32(tokens.len) or
      (previousToken != high(uint32) and symbol.nameToken <= previousToken) or
      tokens[int(symbol.nameToken)].kind != tkIdentifier:
    invalidCache("cache source symbol is invalid")

proc writeSourceIndex(stream: Stream, index: SourceIndex) =
  if index == nil:
    invalidCache("cannot serialize an empty source index")
  stream.write(index.contentHash)
  writeInt(stream, index.byteLength)
  writeInt(stream, index.tokenCount)

  writeCount(stream, index.parsed.tokens.len, maxRecordCount)
  for token in index.parsed.tokens:
    writeToken(stream, token)

  writeCount(stream, index.parsed.imports.len, maxRecordCount)
  for item in index.parsed.imports:
    writeImport(stream, item)

  writeStringSet(stream, index.parsed.localDefinitions)
  writeStringSet(stream, index.parsed.availableNames)
  writeStringSet(stream, index.parsed.qualifiedNames)
  writeStrings(stream, index.imports)
  writeStrings(stream, index.exports)
  writeStrings(stream, index.includes)
  writeCount(stream, index.symbols.len, min(maxRecordCount, index.parsed.tokens.len))
  for symbol in index.symbols:
    writeSourceSymbol(stream, symbol)

proc readSourceIndex(
    stream: Stream, expectedHash: uint64, expectedLength: int
): SourceIndex =
  new(result)
  result.contentHash = stream.readUint64()
  result.byteLength = readInt(stream)
  result.tokenCount = readInt(stream)
  if result.contentHash != expectedHash or result.byteLength != expectedLength:
    invalidCache("cache source fingerprint does not match")

  let tokenCount = readCount(stream, maxRecordCount)
  result.parsed.tokens = newSeqOfCap[Token](tokenCount)
  for _ in 0 ..< tokenCount:
    let token = readToken(stream)
    validateToken(token, expectedLength)
    result.parsed.tokens.add token
  if result.tokenCount != tokenCount:
    invalidCache("cache token count does not match")

  let importCount = readCount(stream, maxRecordCount)
  result.parsed.imports = newSeqOfCap[ImportInfo](importCount)
  for _ in 0 ..< importCount:
    let item = readImport(stream)
    validateImport(item, expectedLength)
    result.parsed.imports.add item

  result.parsed.localDefinitions = readStringSet(stream)
  result.parsed.availableNames = readStringSet(stream)
  result.parsed.qualifiedNames = readStringSet(stream)
  result.imports = readStrings(stream)
  result.exports = readStrings(stream)
  result.includes = readStrings(stream)
  let symbolCount = readCount(stream, min(maxRecordCount, tokenCount))
  result.symbols = newSeqOfCap[SourceSymbol](symbolCount)
  var previousToken = high(uint32)
  for _ in 0 ..< symbolCount:
    let symbol = readSourceSymbol(stream)
    validateSourceSymbol(symbol, result.parsed.tokens, previousToken)
    result.symbols.add symbol
    previousToken = symbol.nameToken
  result.scopes = indexScopes(result.parsed.tokens, result.symbols, result.byteLength)
  if not validateScopes(
    result.scopes, result.parsed.tokens, result.symbols, result.byteLength
  ):
    invalidCache("cache scope index is invalid")
  result.occurrences = indexOccurrences(result.parsed, result.symbols)
  if not validateOccurrences(result.occurrences, result.parsed.tokens):
    invalidCache("cache occurrence index is invalid")

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

proc fileStamp*(path: string): FileStamp =
  try:
    let info = getFileInfo(path)
    result.size = int64(info.size)
    result.modifiedSeconds = info.lastWriteTime.toUnix
    result.modifiedNanoseconds = int32(info.lastWriteTime.nanosecond)
  except CatchableError:
    result.size = -1
    result.modifiedSeconds = -1
    result.modifiedNanoseconds = -1

proc sameFileStamp*(left, right: FileStamp): bool =
  left.size == right.size and left.modifiedSeconds == right.modifiedSeconds and
    left.modifiedNanoseconds == right.modifiedNanoseconds

proc writeManifestPayload(
    stream: Stream, entries: openArray[ManifestEntry], graphValid: bool
) =
  stream.write(manifestGraphVersion)
  writeFlag(stream, graphValid)
  writeCount(stream, entries.len, maxRecordCount)
  for entry in entries:
    writeString(stream, canonicalPath(entry.path))
    stream.write(entry.sourceHash)
    stream.write(entry.byteLength)
    stream.write(entry.stamp.size)
    stream.write(entry.stamp.modifiedSeconds)
    stream.write(entry.stamp.modifiedNanoseconds)
    writeCount(stream, entry.forwardOrdinals.len, maxRecordCount)
    for ordinal in entry.forwardOrdinals:
      stream.write(ordinal)
    writeFlag(stream, entry.unresolved)

proc readManifestPayload(stream: Stream, root: string): ProjectManifest =
  result.root = root
  if stream.readUint32() != manifestGraphVersion:
    invalidCache("manifest graph version does not match")
  result.graphValid = readFlag(stream)
  let count = readCount(stream, maxRecordCount)
  result.entries = newSeqOfCap[ManifestEntry](count)
  var paths = initHashSet[string]()
  var previousEntryPath = ""
  for _ in 0 ..< count:
    let path = canonicalPath(readString(stream))
    if path.len == 0 or path in paths or
        (previousEntryPath.len > 0 and path <= previousEntryPath):
      invalidCache("manifest path is invalid or duplicated")
    paths.incl path
    previousEntryPath = path
    var entry = ManifestEntry(path: path)
    entry.sourceHash = stream.readUint64()
    entry.byteLength = stream.readInt64()
    entry.stamp.size = stream.readInt64()
    entry.stamp.modifiedSeconds = stream.readInt64()
    entry.stamp.modifiedNanoseconds = stream.readInt32()
    if entry.byteLength < 0 or entry.stamp.size < -1 or
        entry.stamp.modifiedNanoseconds < -1 or
        entry.stamp.modifiedNanoseconds >= 1_000_000_000:
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

proc loadProjectManifest*(projectRoot: string): ProjectManifest =
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

proc saveProjectManifest*(
    projectRoot: string, entries: openArray[ManifestEntry], graphValid = false
): bool =
  let root = canonicalPath(projectRoot)
  if root.len == 0:
    return false
  var ordered: seq[ManifestEntry] = @[]
  for entry in entries:
    if entry.path.len == 0 or entry.byteLength < 0:
      return false
    var copied = entry
    copied.path = canonicalPath(entry.path)
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
    writeManifestPayload(payloadStream, ordered, graphValid)
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
): SourceIndex

proc loadCachedSourceIndex*(projectRoot, modulePath, source: string): SourceIndex =
  result = loadCachedSourceIndexFingerprint(
    projectRoot, modulePath, contentFingerprint(source), source.len
  )

proc loadCachedSourceIndexFingerprint*(
    projectRoot, modulePath: string, sourceHash: uint64, byteLength: int
): SourceIndex =
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
): bool =
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
