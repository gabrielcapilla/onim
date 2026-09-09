import ../syntax/tokens

proc integerIndexToken*(tokens: TokenStore, tokenIndex: int): bool {.inline.} =
  if tokenIndex < 0 or tokenIndex >= tokens.len or tokens[tokenIndex].kind != tkNumber:
    return false
  var digits = 0
  for index in 0 ..< tokens.tokenTextLen(tokens[tokenIndex]):
    let character = tokens.tokenTextChar(tokens[tokenIndex], index)
    if character == '_':
      continue
    if character < '0' or character > '9':
      return false
    inc digits
  digits > 0

proc qualifierBeforeDot*(
    tokens: TokenStore, dotToken: int
): tuple[qualifier, indexToken: int] =
  result = (-1, -1)
  if dotToken <= 0 or dotToken >= tokens.len or
      not tokens.tokenTextEquals(tokens[dotToken], "."):
    return
  let direct = dotToken - 1
  if tokens[direct].kind == tkIdentifier and tokens[direct].validIdentifier and
      not tokens[direct].isStropped and not tokens[direct].isNimKeyword and
      tokens[direct].line == tokens[dotToken].line and (
    direct == 0 or not tokens.tokenTextEquals(tokens[direct - 1], ".") or
    tokens[direct - 1].line != tokens[direct].line
  ):
    result.qualifier = direct
    return
  let closing = dotToken - 1
  let indexToken = dotToken - 2
  let opening = dotToken - 3
  let qualifier = dotToken - 4
  if qualifier < 0 or not tokens.tokenTextEquals(tokens[opening], "[") or
      not integerIndexToken(tokens, indexToken) or
      not tokens.tokenTextEquals(tokens[closing], "]") or
      tokens[qualifier].kind != tkIdentifier or not tokens[qualifier].validIdentifier or
      tokens[qualifier].isStropped or tokens[qualifier].isNimKeyword or
      tokens[qualifier].line != tokens[dotToken].line or
      tokens[indexToken].line != tokens[dotToken].line or
      tokens[opening].line != tokens[dotToken].line or
      tokens[closing].line != tokens[dotToken].line or (
    qualifier > 0 and tokens.tokenTextEquals(tokens[qualifier - 1], ".") and
    tokens[qualifier - 1].line == tokens[qualifier].line
  ):
    return
  result = (qualifier, indexToken)

proc qualifiedMember*(
    tokens: TokenStore, tokenIndex: int
): tuple[qualifier, indexToken, member: int] =
  result = (-1, -1, -1)
  if tokenIndex < 1 or not tokens.tokenTextEquals(tokens[tokenIndex - 1], "."):
    return
  let qualifier = qualifierBeforeDot(tokens, tokenIndex - 1)
  if qualifier.qualifier < 0 or (
    tokenIndex + 1 < tokens.len and tokens.tokenTextEquals(tokens[tokenIndex + 1], ".")
  ):
    return
  result = (qualifier.qualifier, qualifier.indexToken, tokenIndex)
