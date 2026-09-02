import std/[algorithm, os, sets, streams, strutils]

import ../syntax/imports
import ../syntax/lexer
import ./source_index

const
  cacheMagic = "ONIMIDX1"
  cacheVersion = 1'u32
  cacheEndian = 1'u8
  maxCacheBytes = 64 * 1024 * 1024
  maxStringBytes = 4 * 1024 * 1024
  maxRecordCount = 1_000_000

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

proc writeImportSymbol(stream: Stream, symbol: ImportSymbol) =
  writeString(stream, symbol.name)
  writeInt(stream, symbol.startOffset)
  writeInt(stream, symbol.endOffset)

proc readImportSymbol(stream: Stream): ImportSymbol =
  result.name = readString(stream)
  result.startOffset = readInt(stream)
  result.endOffset = readInt(stream)

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

proc canonicalPath(path: string): string =
  if path.len == 0:
    return ""
  result = absolutePath(path).replace('\\', '/')

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
    stream: Stream, projectRoot, modulePath, source: string
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
  if sourceHash != contentFingerprint(source) or sourceLength != uint64(source.len):
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
  result = readSourceIndex(payloadStream, contentFingerprint(source), source.len)
  if not payloadStream.atEnd:
    invalidCache("cache payload contains trailing data")

proc loadCachedSourceIndex*(projectRoot, modulePath, source: string): SourceIndex =
  let path = cacheFilePath(projectRoot, modulePath)
  if path.len == 0 or not fileExists(path):
    return
  var stream: FileStream
  try:
    stream = newFileStream(path, fmRead)
    if stream == nil:
      return
    result = readEnvelope(stream, projectRoot, modulePath, source)
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
  let temporary = path & ".tmp"
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
