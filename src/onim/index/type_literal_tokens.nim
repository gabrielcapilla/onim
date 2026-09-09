import ../syntax/tokens

proc tokenTextEqualsAt*(
    tokens: TokenStore, token: Token, first: int, wanted: string
): bool {.inline.} =
  if first < 0 or first + wanted.len > tokens.tokenTextLen(token):
    return false
  for index in 0 ..< wanted.len:
    if tokens.tokenTextChar(token, first + index) != wanted[index]:
      return false
  true

proc sequenceLiteralStart*(tokens: TokenStore, index: int): bool {.inline.} =
  index >= 0 and index + 1 < tokens.len and tokens[index].kind == tkPunctuation and
    tokens[index + 1].kind == tkPunctuation and
    tokens.tokenTextEquals(tokens[index], "@") and
    tokens.tokenTextEquals(tokens[index + 1], "[")
