import std/streams

import ../syntax/imports
import ../syntax/tokens
import ../syntax/parser
import ./cache_wire
import ./occurrences
import ./scopes
import ./scope_validation
import ./source_index
import ./symbols
import ./types
import ./type_index_validation

proc writeToken(stream: Stream, token: Token) =
  stream.write(uint8(ord(token.kind)))
  stream.write(uint8(ord(token.keyword)))
  var flags = 0'u8
  if tfStropped in token.flags:
    flags = flags or 1'u8
  if tfClosed in token.flags:
    flags = flags or 2'u8
  stream.write(flags)
  writeInt(stream, token.startOffset)
  writeInt(stream, token.endOffset)
  writeInt(stream, token.line)
  writeInt(stream, token.column)

proc readToken(stream: Stream): Token =
  let kind = stream.readUint8()
  if kind > uint8(ord(high(TokenKind))):
    invalidCache("cache token kind is invalid")
  result.kind = TokenKind(kind)
  let keyword = stream.readUint8()
  if keyword > uint8(ord(high(NimKeyword))):
    invalidCache("cache token keyword is invalid")
  result.keyword = NimKeyword(keyword)
  let flags = stream.readUint8()
  if flags > 3'u8:
    invalidCache("cache token flags are invalid")
  if (flags and 1'u8) != 0:
    result.flags.incl tfStropped
  if (flags and 2'u8) != 0:
    result.flags.incl tfClosed
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

proc validateToken(token: Token, source: string, sourceLength: int) =
  if not validSpan(token.startOffset, token.endOffset, sourceLength) or token.line < 0 or
      token.column < 0:
    invalidCache("cache token range is invalid")
  if tfStropped in token.flags and token.kind != tkIdentifier:
    invalidCache("cache token strop flag is invalid")
  if tfClosed in token.flags and token.kind notin {tkIdentifier, tkString}:
    invalidCache("cache token closure flag is invalid")
  if token.kind == tkIdentifier and not isStropped(token) and tfClosed in token.flags:
    invalidCache("cache identifier closure flag is invalid")
  if token.kind == tkIdentifier:
    if isStropped(token):
      if token.startOffset >= sourceLength or source[token.startOffset] != '`' or
          token.endOffset - token.startOffset < 2 or
          tfClosed in token.flags and source[token.endOffset - 1] != '`' or
          token.keyword != kwNone:
        invalidCache("cache stropped token is invalid")
    elif token.keyword != keywordIdAt(source, token.startOffset, token.endOffset):
      invalidCache("cache token keyword does not match source")
  elif token.keyword != kwNone:
    invalidCache("cache non-identifier keyword is invalid")

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

proc validateSourceSymbol[T](symbol: SourceSymbol, tokens: T, previousToken: uint32) =
  if symbol.nameToken >= uint32(tokens.len) or
      (previousToken != high(uint32) and symbol.nameToken <= previousToken) or
      tokens[int(symbol.nameToken)].kind != tkIdentifier:
    invalidCache("cache source symbol is invalid")

proc writeSourceIndex*(stream: Stream, index: SourceIndex) =
  if index == nil:
    invalidCache("cannot serialize an empty source index")
  let source = index.parsed.tokens.sourceText
  if source.len != index.byteLength or contentFingerprint(source) != index.contentHash:
    invalidCache("source index buffer does not match fingerprint")
  stream.write(index.contentHash)
  writeInt(stream, index.byteLength)
  writeInt(stream, index.tokenCount)
  writeString(stream, source)

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
  writeFlag(stream, index.hasUnresolvedExports)
  writeStrings(stream, index.includes)
  writeCount(stream, index.symbols.len, min(maxRecordCount, index.parsed.tokens.len))
  for symbol in index.symbols:
    writeSourceSymbol(stream, symbol)

proc readSourceIndex*(
    stream: Stream, expectedHash: uint64, expectedLength: int
): SourceIndex =
  new(result)
  result.contentHash = stream.readUint64()
  result.byteLength = readInt(stream)
  result.tokenCount = readInt(stream)
  if result.contentHash != expectedHash or result.byteLength != expectedLength:
    invalidCache("cache source fingerprint does not match")
  let source = readString(stream)
  if source.len != expectedLength or contentFingerprint(source) != expectedHash:
    invalidCache("cache source buffer does not match fingerprint")

  let tokenCount = readCount(stream, maxRecordCount)
  var tokens = newSeqOfCap[Token](tokenCount)
  var previousEnd = 0
  for _ in 0 ..< tokenCount:
    let token = readToken(stream)
    validateToken(token, source, expectedLength)
    if token.startOffset < previousEnd:
      invalidCache("cache token order is invalid")
    tokens.add token
    previousEnd = token.endOffset
  result.parsed.tokens = initTokenStore(source, tokens)
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
  result.hasUnresolvedExports = readFlag(stream)
  result.includes = readStrings(stream)
  let symbolCount = readCount(stream, min(maxRecordCount, tokenCount))
  result.symbols = newSeqOfCap[SourceSymbol](symbolCount)
  var previousToken = high(uint32)
  for _ in 0 ..< symbolCount:
    let symbol = readSourceSymbol(stream)
    validateSourceSymbol(symbol, result.parsed.tokens, previousToken)
    result.symbols.add symbol
    previousToken = symbol.nameToken
  result.syntax = parsePartialSyntax(result.parsed.tokens, source)
  if not result.syntax.validateSyntaxTree or
      not result.syntax.importsMatch(result.parsed):
    invalidCache("cache syntax tree is invalid")
  result.scopes =
    indexScopes(result.parsed.tokens, result.symbols, result.byteLength, result.syntax)
  if not validateScopes(
    result.scopes, result.parsed.tokens, result.symbols, result.byteLength
  ):
    invalidCache("cache scope index is invalid")
  result.types = indexTypes(result.parsed.tokens, result.symbols, result.scopes)
  if not validateTypeIndex(
    result.types, result.parsed.tokens, result.symbols, result.scopes
  ):
    invalidCache("cache type index is invalid")
  result.occurrences = indexOccurrences(result.parsed, result.symbols)
  if not validateOccurrences(result.occurrences, result.parsed.tokens):
    invalidCache("cache occurrence index is invalid")
  result.initializeNativeIndexSafety()
