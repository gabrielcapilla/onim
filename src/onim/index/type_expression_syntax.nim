import ../syntax/tokens
import ./scopes
import ./type_declaration_syntax

proc splitDeclaration*(
    tokens: TokenStore, declaration: LexicalDeclaration
): tuple[colon, equals: int] =
  result = (-1, -1)
  var delimiters: seq[char] = @[]
  for index in int(declaration.firstToken) ..< int(declaration.pastToken):
    if tokens.tokenTextEquals(tokens[index], "(") or
        tokens.tokenTextEquals(tokens[index], "[") or
        tokens.tokenTextEquals(tokens[index], "{"):
      delimiters.add tokens.tokenTextChar(tokens[index], 0)
    elif tokens.tokenTextEquals(tokens[index], ")") or
        tokens.tokenTextEquals(tokens[index], "]") or
        tokens.tokenTextEquals(tokens[index], "}"):
      let delimiter = tokens.tokenTextChar(tokens[index], 0)
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], delimiter):
        return
      delimiters.setLen(delimiters.len - 1)
    elif delimiters.len == 0:
      if tokens.tokenTextEquals(tokens[index], ":") and result.colon < 0:
        result.colon = index
      elif tokens.tokenTextEquals(tokens[index], "=") and result.equals < 0:
        result.equals = index

proc directTypeAnnotationToken*(
    tokens: TokenStore, declaration: LexicalDeclaration, tokenIndex: int
): bool =
  if tokenIndex < int(declaration.firstToken) or tokenIndex >= int(
    declaration.pastToken
  ):
    return false
  let split = splitDeclaration(tokens, declaration)
  split.colon >= 0 and tokenIndex == split.colon + 1 and
    (split.equals < 0 or tokenIndex < split.equals)

proc nominalTypeToken*(tokens: TokenStore, first, past: int): uint32 =
  var cursor = first
  if cursor < past and tokens[cursor].isKeyword(kwPtr):
    inc cursor
  if cursor >= past or not validNameToken(tokens, cursor):
    return high(uint32)
  if cursor + 1 == past:
    return uint32(cursor)
  if cursor + 3 == past and tokens.tokenTextEquals(tokens[cursor + 1], ".") and
      validNameToken(tokens, cursor + 2):
    return uint32(cursor + 2)
  high(uint32)
