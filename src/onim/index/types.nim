import ../syntax/lexer
import ./scopes
import ./symbols

type
  ObjectFieldVisibility* = enum
    objectFieldPrivate
    objectFieldExported

  ObjectTypeRecord* = object
    declarationToken*: uint32
    firstField*: uint32
    pastField*: uint32

  ObjectField* = object
    nameToken*: uint32
    visibility*: ObjectFieldVisibility

  LocalTypeKind* = enum
    localTypeUnknown
    localTypeNamed
    localTypeBool
    localTypeChar
    localTypeString
    localTypeInt

  LocalTypeForm* = enum
    localTypeFormUnknown
    localTypeFormAnnotation
    localTypeFormCall
    localTypeFormLiteral

  LocalTypeInfo* = object
    kind*: LocalTypeKind
    form*: LocalTypeForm
    typeToken*: uint32
    firstToken*: uint32
    pastToken*: uint32

  TypeIndex* = object
    objects*: seq[ObjectTypeRecord]
    fields*: seq[ObjectField]
    localTypeUses*: seq[uint32]
    routineReturnTypeUses*: seq[uint32]

const InvalidTypeToken* = high(uint32)

proc validNameToken(tokens: TokenStore, index: int): bool {.inline.} =
  if index < 0 or index >= tokens.len:
    return false
  let token = tokens[index]
  token.kind == tkIdentifier and token.validIdentifier and not token.isStropped and
    not isNimKeyword(token)

proc typeDeclarationEnd(tokens: TokenStore, nameToken: int): int =
  if nameToken < 0 or nameToken >= tokens.len:
    return -1
  let line = tokens[nameToken].line
  var column = tokens[nameToken].column
  var cursor = nameToken - 1
  while cursor >= 0 and tokens[cursor].line == line:
    if tokens[cursor].isKeyword(kwType):
      column = tokens[cursor].column
      break
    dec cursor
  result = tokens.len
  for index in nameToken + 1 ..< tokens.len:
    if tokens[index].line > line and tokens[index].column <= column:
      return index

proc objectKeyword(tokens: TokenStore, nameToken, limit: int): int =
  if nameToken < 0 or nameToken >= limit:
    return -1
  var cursor = nameToken + 1
  if cursor < limit and tokens[cursor].text == "*":
    inc cursor
  if cursor >= limit or tokens[cursor].text != "=" or
      tokens[cursor].line != tokens[nameToken].line:
    return -1
  inc cursor
  if cursor < limit and
      (tokens[cursor].isKeyword(kwRef) or tokens[cursor].isKeyword(kwPtr)):
    inc cursor
  if cursor >= limit or not tokens[cursor].isKeyword(kwObject) or
      tokens[cursor].line != tokens[nameToken].line:
    return -1
  result = cursor
  inc cursor
  if cursor < limit and tokens[cursor].line == tokens[result].line:
    return -1

proc addField(tokens: TokenStore, tokenIndex: int, fields: var seq[ObjectField]): bool =
  if not validNameToken(tokens, tokenIndex):
    return false
  let token = tokens[tokenIndex]
  for field in fields:
    if sameIdentifier(tokens[int(field.nameToken)].text, token.text):
      return false
  fields.add ObjectField(
    nameToken: uint32(tokenIndex),
    visibility:
      if tokenIndex + 1 < tokens.len and tokens[tokenIndex + 1].line == token.line and
          tokens[tokenIndex + 1].text == "*":
        objectFieldExported
      else:
        objectFieldPrivate,
  )
  true

proc parseFieldSegment(
    tokens: TokenStore, first, past: int, fields: var seq[ObjectField]
): bool =
  if first >= past:
    return true
  var colon = -1
  var depth = 0
  for index in first ..< past:
    let text = tokens[index].text
    if text == "(" or text == "[" or text == "{":
      inc depth
    elif text == ")" or text == "]" or text == "}":
      if depth == 0:
        return false
      dec depth
    elif depth == 0 and text == ":":
      colon = index
      break
  if colon <= first or colon + 1 >= past:
    return false

  var names: seq[int] = @[]
  var expectedName = true
  for index in first ..< colon:
    let token = tokens[index]
    if token.text == ",":
      if expectedName:
        return false
      expectedName = true
    elif token.text == "*":
      if expectedName or index == first or tokens[index - 1].kind != tkIdentifier:
        return false
    elif validNameToken(tokens, index):
      if not expectedName:
        return false
      names.add index
      expectedName = false
    else:
      return false
  if names.len == 0 or expectedName:
    return false

  for nameToken in names:
    if not addField(tokens, nameToken, fields):
      return false
  true

proc parseFieldLine(
    tokens: TokenStore, first, past: int, fields: var seq[ObjectField]
): bool =
  var segment = first
  for index in first ..< past:
    if tokens[index].text != ";":
      continue
    if not parseFieldSegment(tokens, segment, index, fields):
      return false
    segment = index + 1
  if segment < past and not parseFieldSegment(tokens, segment, past, fields):
    return false
  true

proc parseObjectFields(
    tokens: TokenStore, nameToken, objectToken, limit: int, fields: var seq[ObjectField]
): bool =
  var baseColumn = tokens[nameToken].column
  var declarationToken = nameToken - 1
  while declarationToken >= 0 and tokens[declarationToken].line == tokens[nameToken].line:
    if tokens[declarationToken].isKeyword(kwType):
      baseColumn = tokens[declarationToken].column
      break
    dec declarationToken
  let objectLine = tokens[objectToken].line
  var fieldIndent = -1
  var cursor = objectToken + 1
  while cursor < limit:
    let token = tokens[cursor]
    if token.text == "{" or token.text == "}":
      return false
    if token.line <= objectLine:
      inc cursor
      continue
    if token.column <= baseColumn:
      return false
    if fieldIndent < 0:
      fieldIndent = token.column
    elif token.column < fieldIndent:
      return false
    if token.column == fieldIndent and (
      cursor == objectToken + 1 or tokens[cursor - 1].line != token.line or
      tokens[cursor - 1].text == ";"
    ):
      var linePast = cursor + 1
      while linePast < limit and tokens[linePast].line == token.line:
        inc linePast
      if not parseFieldLine(tokens, cursor, linePast, fields):
        return false
      cursor = linePast
      continue
    inc cursor
  true

proc indexObject(tokens: TokenStore, symbol: SourceSymbol, types: var TypeIndex): bool =
  let nameToken = int(symbol.nameToken)
  let limit = typeDeclarationEnd(tokens, nameToken)
  let objectToken = objectKeyword(tokens, nameToken, limit)
  if objectToken < 0:
    return false
  let firstField = types.fields.len
  if not parseObjectFields(tokens, nameToken, objectToken, limit, types.fields):
    types.fields.setLen(firstField)
    return false
  types.objects.add ObjectTypeRecord(
    declarationToken: symbol.nameToken,
    firstField: uint32(firstField),
    pastField: uint32(types.fields.len),
  )
  true

proc splitDeclaration(
    tokens: TokenStore, declaration: LexicalDeclaration
): tuple[colon, equals: int] =
  result = (-1, -1)
  var delimiters: seq[char] = @[]
  for index in int(declaration.firstToken) ..< int(declaration.pastToken):
    let text = tokens[index].text
    if text == "(" or text == "[" or text == "{":
      delimiters.add text[0]
    elif text == ")" or text == "]" or text == "}":
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], text[0]):
        return
      delimiters.setLen(delimiters.len - 1)
    elif delimiters.len == 0:
      if text == ":" and result.colon < 0:
        result.colon = index
      elif text == "=" and result.equals < 0:
        result.equals = index

proc nominalTypeToken(tokens: TokenStore, first, past: int): uint32 =
  var cursor = first
  if cursor < past and
      (tokens[cursor].isKeyword(kwRef) or tokens[cursor].isKeyword(kwPtr)):
    inc cursor
  if cursor >= past or not validNameToken(tokens, cursor):
    return InvalidTypeToken
  if cursor + 1 == past:
    return uint32(cursor)
  if cursor + 3 == past and tokens[cursor + 1].text == "." and
      validNameToken(tokens, cursor + 2):
    return uint32(cursor + 2)
  InvalidTypeToken

proc directCallInfo(tokens: TokenStore, first, past: int): LocalTypeInfo =
  if first >= past or not validNameToken(tokens, first):
    return
  var nameToken = first
  if first + 2 < past and tokens[first + 1].text == "." and
      validNameToken(tokens, first + 2):
    nameToken = first + 2
  if nameToken + 1 >= past or tokens[nameToken + 1].text != "(":
    return
  var delimiters: seq[char] = @[]
  for index in nameToken + 1 ..< past:
    let text = tokens[index].text
    if text == "(" or text == "[" or text == "{":
      delimiters.add text[0]
    elif text == ")" or text == "]" or text == "}":
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], text[0]):
        return
      delimiters.setLen(delimiters.len - 1)
      if delimiters.len == 0 and index + 1 != past:
        return
  if delimiters.len != 0:
    return
  result.kind = localTypeNamed
  result.form = localTypeFormCall
  result.typeToken = uint32(nameToken)
  result.firstToken = uint32(first)
  result.pastToken = uint32(nameToken + 1)

proc typeUseFor(tokens: TokenStore, declaration: LexicalDeclaration): uint32 =
  let split = splitDeclaration(tokens, declaration)
  if split.colon >= 0:
    let past =
      if split.equals > split.colon:
        split.equals
      else:
        int(declaration.pastToken)
    return nominalTypeToken(tokens, split.colon + 1, past)
  if split.equals >= 0:
    let call = directCallInfo(tokens, split.equals + 1, int(declaration.pastToken))
    if call.form == localTypeFormCall:
      return call.typeToken
  InvalidTypeToken

proc directLiteralKind(tokens: TokenStore, first, past: int): LocalTypeKind =
  if first < 0 or first >= past or past > tokens.len:
    return localTypeUnknown
  if past == first + 1:
    let token = tokens[first]
    if token.kind == tkIdentifier:
      case token.text
      of "true", "false":
        return localTypeBool
      else:
        discard
    elif token.kind == tkString and isClosedString(token):
      if token.text[0] == '"':
        if token.text.len >= 3 and token.text[1] == '"' and token.text[2] == '"':
          return localTypeUnknown
        return localTypeString
      if token.text[0] == char(39) and token.text.len >= 3:
        return localTypeChar
    elif token.kind == tkPunctuation and token.text.len == 1 and token.text[0] >= '0' and
        token.text[0] <= '9':
      return localTypeInt
    return localTypeUnknown

  var previousEnd = -1
  for index in first ..< past:
    let token = tokens[index]
    if token.kind != tkPunctuation or token.text.len != 1 or token.text[0] < '0' or
        token.text[0] > '9' or (previousEnd >= 0 and token.startOffset != previousEnd):
      return localTypeUnknown
    previousEnd = token.endOffset
  localTypeInt

proc localTypeAt*(
    types: TypeIndex, tokens: TokenStore, scopes: ScopeIndex, declarationToken: uint32
): LocalTypeInfo =
  if types.localTypeUses.len != scopes.declarations.len:
    return
  let declarationOrdinal = scopes.declarationOrdinalAt(declarationToken)
  if declarationOrdinal < 0 or declarationOrdinal >= scopes.declarations.len:
    return
  let declaration = scopes.declarations[declarationOrdinal]
  if declaration.pastToken > uint32(tokens.len):
    return
  let split = splitDeclaration(tokens, declaration)
  if split.colon >= 0:
    let past =
      if split.equals > split.colon:
        split.equals
      else:
        int(declaration.pastToken)
    let typeToken = typeUseFor(tokens, declaration)
    if typeToken == InvalidTypeToken or
        types.localTypeUses[declarationOrdinal] != typeToken:
      return
    result.kind = localTypeNamed
    result.form = localTypeFormAnnotation
    result.typeToken = typeToken
    result.firstToken = uint32(split.colon + 1)
    result.pastToken = uint32(past)
    return
  if split.equals < 0:
    return

  let call = directCallInfo(tokens, split.equals + 1, int(declaration.pastToken))
  if call.form == localTypeFormCall:
    if types.localTypeUses[declarationOrdinal] != call.typeToken:
      return
    return call

  result.kind = directLiteralKind(tokens, split.equals + 1, int(declaration.pastToken))
  if result.kind != localTypeUnknown:
    result.form = localTypeFormLiteral
    result.firstToken = uint32(split.equals + 1)
    result.pastToken = declaration.pastToken

proc routineReturnSpan(
    tokens: TokenStore, symbol: SourceSymbol
): tuple[typeToken: uint32, first, past: int] =
  result.typeToken = InvalidTypeToken
  result.first = -1
  result.past = -1
  if symbol.kind notin {symbolProc, symbolFunc} or symbol.nameToken >= uint32(
    tokens.len
  ):
    return
  let nameToken = int(symbol.nameToken)
  if nameToken <= 0 or
      not tokens[nameToken - 1].isKeyword(kwProc) and
      not tokens[nameToken - 1].isKeyword(kwFunc):
    return
  var opening = nameToken + 1
  if opening < tokens.len and tokens[opening].text == "*":
    inc opening
  if opening >= tokens.len or tokens[opening].text != "(":
    return

  var delimiters: seq[char] = @[]
  var closing = -1
  for index in opening ..< tokens.len:
    let text = tokens[index].text
    if text.len == 1 and isOpeningDelimiter(text[0]):
      delimiters.add text[0]
    elif text.len == 1 and isClosingDelimiter(text[0]):
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], text[0]):
        return
      delimiters.setLen(delimiters.len - 1)
      if delimiters.len == 0:
        closing = index
        break
  if closing < 0 or closing + 1 >= tokens.len or tokens[closing + 1].text != ":":
    return

  let first = closing + 2
  var past = first
  while past < tokens.len and tokens[past].text != "=":
    inc past
  if first >= past:
    return
  let typeToken = nominalTypeToken(tokens, first, past)
  if typeToken == InvalidTypeToken:
    return
  result.typeToken = typeToken
  result.first = first
  result.past = past

proc routineReturnAt*(
    types: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    symbolOrdinal: int,
): LocalTypeInfo =
  if types.routineReturnTypeUses.len != symbols.len or symbolOrdinal < 0 or
      symbolOrdinal >= symbols.len:
    return
  if types.routineReturnTypeUses[symbolOrdinal] == InvalidTypeToken:
    return
  let span = routineReturnSpan(tokens, symbols[symbolOrdinal])
  if span.typeToken != types.routineReturnTypeUses[symbolOrdinal]:
    return
  result.kind = localTypeNamed
  result.form = localTypeFormAnnotation
  result.typeToken = span.typeToken
  result.firstToken = uint32(span.first)
  result.pastToken = uint32(span.past)

proc indexTypes*(
    tokens: TokenStore, symbols: openArray[SourceSymbol], scopes: ScopeIndex
): TypeIndex =
  result.localTypeUses = newSeq[uint32](scopes.declarations.len)
  for declarationIndex, declaration in scopes.declarations:
    result.localTypeUses[declarationIndex] = typeUseFor(tokens, declaration)
  result.routineReturnTypeUses = newSeq[uint32](symbols.len)
  for symbolIndex, symbol in symbols:
    result.routineReturnTypeUses[symbolIndex] =
      routineReturnSpan(tokens, symbol).typeToken
    if symbol.kind == symbolType:
      discard indexObject(tokens, symbol, result)

proc objectOrdinal*(index: TypeIndex, declarationToken: uint32): int {.inline.} =
  var first = 0
  var past = index.objects.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.objects[middle].declarationToken
    if candidate < declarationToken:
      first = middle + 1
    elif candidate > declarationToken:
      past = middle
    else:
      return middle
  -1

proc objectFieldOrdinal*(index: TypeIndex, nameToken: uint32): int {.inline.} =
  var first = 0
  var past = index.fields.len
  while first < past:
    let middle = (first + past) div 2
    let candidate = index.fields[middle].nameToken
    if candidate < nameToken:
      first = middle + 1
    elif candidate > nameToken:
      past = middle
    else:
      return middle
  -1

proc objectFieldExportMarker*(index: TypeIndex, tokenIndex: uint32): bool {.inline.} =
  if tokenIndex == 0:
    return false
  let ordinal = index.objectFieldOrdinal(tokenIndex - 1'u32)
  ordinal >= 0 and index.fields[ordinal].visibility == objectFieldExported

proc objectOrdinalForType*(
    index: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    typeToken: uint32,
): int =
  if typeToken == InvalidTypeToken or not validNameToken(tokens, int(typeToken)):
    return -1
  let wanted = identifierKey(tokens[int(typeToken)].text)
  var found = -1
  var matches = 0
  for symbol in symbols:
    if symbol.kind != symbolType or symbol.nameToken >= uint32(tokens.len):
      continue
    if identifierKey(tokens[int(symbol.nameToken)].text) != wanted:
      continue
    inc matches
    let ordinal = index.objectOrdinal(symbol.nameToken)
    if ordinal < 0:
      return -1
    found = ordinal
  if matches == 1: found else: -1

proc validateTypeIndex*(
    index: TypeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    scopes: ScopeIndex,
): bool =
  if index.localTypeUses.len != scopes.declarations.len or
      index.routineReturnTypeUses.len != symbols.len:
    return false
  var previousObject = high(uint32)
  for objectType in index.objects:
    if objectType.declarationToken >= uint32(tokens.len) or (
      previousObject != high(uint32) and objectType.declarationToken <= previousObject
    ) or objectType.firstField > objectType.pastField or
        objectType.pastField > uint32(index.fields.len):
      return false
    previousObject = objectType.declarationToken
    var symbolMatches = 0
    for symbol in symbols:
      if symbol.kind == symbolType and symbol.nameToken == objectType.declarationToken:
        inc symbolMatches
    if symbolMatches != 1:
      return false
    let limit = typeDeclarationEnd(tokens, int(objectType.declarationToken))
    if limit < 0:
      return false
    if objectType.pastField > objectType.firstField:
      for fieldIndex in objectType.firstField ..< objectType.pastField:
        let fieldToken = index.fields[int(fieldIndex)].nameToken
        if fieldToken <= objectType.declarationToken or fieldToken >= uint32(limit) or
            not validNameToken(tokens, int(fieldToken)):
          return false
        for previous in objectType.firstField ..< fieldIndex:
          if sameIdentifier(
            tokens[int(index.fields[int(previous)].nameToken)].text,
            tokens[int(fieldToken)].text,
          ):
            return false
  for declarationIndex, typeToken in index.localTypeUses:
    if typeToken == InvalidTypeToken:
      continue
    let declaration = scopes.declarations[declarationIndex]
    if typeToken < declaration.firstToken or typeToken >= declaration.pastToken or
        not validNameToken(tokens, int(typeToken)):
      return false
  for symbolIndex, typeToken in index.routineReturnTypeUses:
    if typeToken == InvalidTypeToken:
      continue
    if symbolIndex >= symbols.len or
        routineReturnSpan(tokens, symbols[symbolIndex]).typeToken != typeToken:
      return false
  true
