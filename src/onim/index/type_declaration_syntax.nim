import ../syntax/tokens

proc validNameToken*(tokens: TokenStore, index: int): bool {.inline.} =
  if index < 0 or index >= tokens.len:
    return false
  let token = tokens[index]
  token.kind == tkIdentifier and token.validIdentifier and not token.isStropped and
    not isNimKeyword(token)

proc genericParameterBounds*(
    tokens: TokenStore, nameToken, limit: int
): tuple[first, past, after: int, present, valid: bool] =
  result.after = nameToken + 1
  result.valid = true
  if nameToken < 0 or nameToken >= limit:
    result.valid = false
    return
  var cursor = nameToken + 1
  if cursor < limit and tokens.tokenTextEquals(tokens[cursor], "*"):
    inc cursor
  if cursor >= limit or not tokens.tokenTextEquals(tokens[cursor], "["):
    result.after = cursor
    return
  result.present = true
  result.first = cursor + 1
  inc cursor
  while cursor < limit:
    if tokens.tokenTextEquals(tokens[cursor], "["):
      result.valid = false
      return
    if tokens.tokenTextEquals(tokens[cursor], "]"):
      if cursor == result.first:
        result.valid = false
        return
      result.past = cursor
      result.after = cursor + 1
      return
    inc cursor
  result.valid = false

proc typeDeclarationEnd*(tokens: TokenStore, nameToken: int): int =
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

proc objectKeyword*(tokens: TokenStore, nameToken, limit: int): int =
  if nameToken < 0 or nameToken >= limit:
    return -1
  var cursor = nameToken + 1
  if cursor < limit and tokens.tokenTextEquals(tokens[cursor], "*"):
    inc cursor
  let generic = genericParameterBounds(tokens, nameToken, limit)
  if not generic.valid:
    return -1
  cursor = generic.after
  if cursor >= limit or not tokens.tokenTextEquals(tokens[cursor], "=") or
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

proc tupleKeyword*(tokens: TokenStore, nameToken, limit: int): int =
  if nameToken < 0 or nameToken >= limit:
    return -1
  let bounds = genericParameterBounds(tokens, nameToken, limit)
  if not bounds.valid or bounds.present or bounds.after >= limit or
      not tokens.tokenTextEquals(tokens[bounds.after], "=") or
      tokens[bounds.after].line != tokens[nameToken].line:
    return -1
  let tupleToken = bounds.after + 1
  if tupleToken >= limit or not tokens[tupleToken].isKeyword(kwTuple) or
      tokens[tupleToken].line != tokens[nameToken].line:
    return -1
  tupleToken

proc enumKeyword*(tokens: TokenStore, nameToken, limit: int): int =
  if nameToken < 0 or nameToken >= limit:
    return -1
  let bounds = genericParameterBounds(tokens, nameToken, limit)
  if not bounds.valid or bounds.present or bounds.after >= limit or
      not tokens.tokenTextEquals(tokens[bounds.after], "=") or
      tokens[bounds.after].line != tokens[nameToken].line:
    return -1
  let enumToken = bounds.after + 1
  if enumToken >= limit or not tokens[enumToken].isKeyword(kwEnum) or
      tokens[enumToken].line != tokens[nameToken].line:
    return -1
  enumToken

proc simpleEnumDeclaration*(tokens: TokenStore, nameToken: uint32): bool =
  if nameToken == high(uint32) or nameToken >= uint32(tokens.len):
    return false
  enumKeyword(tokens, int(nameToken), typeDeclarationEnd(tokens, int(nameToken))) >= 0

proc parseGenericParameters*(
    tokens: TokenStore, nameToken, objectToken: int, parameters: var seq[uint32]
): bool =
  let bounds = genericParameterBounds(tokens, nameToken, objectToken)
  if not bounds.valid or bounds.after >= objectToken or
      not tokens.tokenTextEquals(tokens[bounds.after], "="):
    return false
  var objectHeader = bounds.after + 1
  if objectHeader < objectToken and
      (tokens[objectHeader].isKeyword(kwRef) or tokens[objectHeader].isKeyword(kwPtr)):
    inc objectHeader
  if objectHeader != objectToken:
    return false
  if not bounds.present:
    return true
  var expectedName = true
  for index in bounds.first ..< bounds.past:
    let token = tokens[index]
    if tokens.tokenTextEquals(token, ","):
      if expectedName:
        return false
      expectedName = true
    elif validNameToken(tokens, index):
      if not expectedName:
        return false
      parameters.add uint32(index)
      expectedName = false
    else:
      return false
  if expectedName or parameters.len == 0:
    return false
  for parameterIndex, parameter in parameters:
    for previous in 0 ..< parameterIndex:
      if sameIdentifier(
        tokens.tokenText(tokens[int(parameters[previous])]),
        tokens.tokenText(tokens[int(parameter)]),
      ):
        return false
  true
