import std/sets

import ../syntax/tokens
import ./type_declaration_syntax
import ./type_index_models

proc addField(
    tokens: TokenStore,
    tokenIndex: int,
    fields: var seq[ObjectField],
    seen: var HashSet[string],
    defaultVisibility = objectFieldPrivate,
): bool =
  if not validNameToken(tokens, tokenIndex):
    return false
  let token = tokens[tokenIndex]
  let key = tokens.identifierKey(token)
  if key.len == 0 or key in seen:
    return false
  seen.incl key
  fields.add ObjectField(
    nameToken: uint32(tokenIndex),
    visibility:
      if tokenIndex + 1 < tokens.len and tokens[tokenIndex + 1].line == token.line and
          tokens.tokenTextEquals(tokens[tokenIndex + 1], "*"):
        objectFieldExported
      else:
        defaultVisibility,
  )
  true

proc parseFieldSegment(
    tokens: TokenStore,
    first, past: int,
    fields: var seq[ObjectField],
    seen: var HashSet[string],
    defaultVisibility = objectFieldPrivate,
): bool =
  if first >= past:
    return true
  var colon = -1
  var depth = 0
  for index in first ..< past:
    if tokens.tokenTextEquals(tokens[index], "(") or
        tokens.tokenTextEquals(tokens[index], "[") or
        tokens.tokenTextEquals(tokens[index], "{"):
      inc depth
    elif tokens.tokenTextEquals(tokens[index], ")") or
        tokens.tokenTextEquals(tokens[index], "]") or
        tokens.tokenTextEquals(tokens[index], "}"):
      if depth == 0:
        return false
      dec depth
    elif depth == 0 and tokens.tokenTextEquals(tokens[index], ":"):
      colon = index
      break
  if colon <= first or colon + 1 >= past:
    return false

  var names: seq[int] = @[]
  var expectedName = true
  for index in first ..< colon:
    let token = tokens[index]
    if tokens.tokenTextEquals(token, ","):
      if expectedName:
        return false
      expectedName = true
    elif tokens.tokenTextEquals(token, "*"):
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
    if not addField(tokens, nameToken, fields, seen, defaultVisibility):
      return false
  true

proc parseFieldLine(
    tokens: TokenStore,
    first, past: int,
    fields: var seq[ObjectField],
    seen: var HashSet[string],
    defaultVisibility = objectFieldPrivate,
): bool =
  var segment = first
  for index in first ..< past:
    if not tokens.tokenTextEquals(tokens[index], ";"):
      continue
    if not parseFieldSegment(tokens, segment, index, fields, seen, defaultVisibility):
      return false
    segment = index + 1
  if segment < past and
      not parseFieldSegment(tokens, segment, past, fields, seen, defaultVisibility):
    return false
  true

proc parseObjectFields*(
    tokens: TokenStore, nameToken, objectToken, limit: int, fields: var seq[ObjectField]
): bool =
  var seen = initHashSet[string]()
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
    if tokens.tokenTextEquals(token, "{") or tokens.tokenTextEquals(token, "}"):
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
      tokens.tokenTextEquals(tokens[cursor - 1], ";")
    ):
      var linePast = cursor + 1
      while linePast < limit and tokens[linePast].line == token.line:
        inc linePast
      if not parseFieldLine(tokens, cursor, linePast, fields, seen):
        return false
      cursor = linePast
      continue
    inc cursor
  true

proc parseTupleFieldSegment(
    tokens: TokenStore,
    first, past: int,
    fields: var seq[ObjectField],
    seen: var HashSet[string],
): bool =
  if first >= past:
    return false
  for index in first ..< past:
    if tokens[index].isKeyword(kwTuple):
      return false
  parseFieldSegment(tokens, first, past, fields, seen, objectFieldExported)

proc parseTupleFields*(
    tokens: TokenStore, tupleToken, limit: int, fields: var seq[ObjectField]
): bool =
  var seen = initHashSet[string]()
  let opening = tupleToken + 1
  if opening >= limit or not tokens.tokenTextEquals(tokens[opening], "["):
    return false
  var segment = opening + 1
  var delimiters: seq[char] = @[]
  var closing = -1
  for cursor in segment ..< limit:
    let token = tokens[cursor]
    if tokens.tokenTextEquals(token, "(") or tokens.tokenTextEquals(token, "[") or
        tokens.tokenTextEquals(token, "{"):
      delimiters.add tokens.tokenTextChar(token, 0)
    elif tokens.tokenTextEquals(token, ")") or tokens.tokenTextEquals(token, "]") or
        tokens.tokenTextEquals(token, "}"):
      let delimiter = tokens.tokenTextChar(token, 0)
      if delimiters.len > 0:
        if not matchingDelimiter(delimiters[^1], delimiter):
          return false
        delimiters.setLen(delimiters.len - 1)
      elif delimiter == ']':
        if not parseTupleFieldSegment(tokens, segment, cursor, fields, seen):
          return false
        closing = cursor
        break
      else:
        return false
    elif delimiters.len == 0 and tokens.tokenTextEquals(token, ","):
      if not parseTupleFieldSegment(tokens, segment, cursor, fields, seen):
        return false
      segment = cursor + 1
  if closing < 0 or fields.len == 0:
    return false
  if closing + 1 < limit and tokens[closing + 1].line == tokens[tupleToken].line:
    return false
  true

proc parseTupleLiteralFieldSegment(
    tokens: TokenStore,
    first, past: int,
    fields: var seq[ObjectField],
    seen: var HashSet[string],
): bool =
  if first + 2 >= past or not validNameToken(tokens, first) or
      not tokens.tokenTextEquals(tokens[first + 1], ":"):
    return false
  addField(tokens, first, fields, seen)

proc parseTupleLiteralFields*(
    tokens: TokenStore, first, past: int, fields: var seq[ObjectField]
): bool =
  var seen = initHashSet[string]()
  if first < 0 or first + 2 >= past or past > tokens.len or
      not tokens.tokenTextEquals(tokens[first], "(") or
      not tokens.tokenTextEquals(tokens[past - 1], ")"):
    return false
  var delimiters: seq[char] = @[]
  var segment = first + 1
  for cursor in first + 1 ..< past - 1:
    let token = tokens[cursor]
    if tokens.tokenTextEquals(token, "(") or tokens.tokenTextEquals(token, "[") or
        tokens.tokenTextEquals(token, "{"):
      delimiters.add tokens.tokenTextChar(token, 0)
    elif tokens.tokenTextEquals(token, ")") or tokens.tokenTextEquals(token, "]") or
        tokens.tokenTextEquals(token, "}"):
      if delimiters.len == 0 or
          not matchingDelimiter(delimiters[^1], tokens.tokenTextChar(token, 0)):
        return false
      delimiters.setLen(delimiters.len - 1)
    elif delimiters.len == 0 and tokens.tokenTextEquals(token, ","):
      if not parseTupleLiteralFieldSegment(tokens, segment, cursor, fields, seen):
        return false
      segment = cursor + 1
  if delimiters.len != 0 or
      not parseTupleLiteralFieldSegment(tokens, segment, past - 1, fields, seen):
    return false
  fields.len > 0

proc parseEnumFields*(
    tokens: TokenStore, nameToken, enumToken, limit: int, fields: var seq[ObjectField]
): bool =
  var baseColumn = tokens[nameToken].column
  var declarationToken = nameToken - 1
  while declarationToken >= 0 and tokens[declarationToken].line == tokens[nameToken].line:
    if tokens[declarationToken].isKeyword(kwType):
      baseColumn = tokens[declarationToken].column
      break
    dec declarationToken
  var expectName = true
  var sawField = false
  var cursor = enumToken + 1
  while cursor < limit:
    let token = tokens[cursor]
    if token.line <= tokens[enumToken].line:
      inc cursor
      continue
    if token.column <= baseColumn:
      return sawField and not expectName
    if validNameToken(tokens, cursor):
      if not expectName:
        return false
      fields.add ObjectField(nameToken: uint32(cursor), visibility: objectFieldExported)
      expectName = false
      sawField = true
    elif tokens.tokenTextEquals(token, ","):
      if expectName:
        return false
      expectName = true
    else:
      return false
    inc cursor
  sawField and not expectName
