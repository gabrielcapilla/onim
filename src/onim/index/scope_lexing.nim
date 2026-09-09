import ../syntax/tokens
import ./symbols

proc malformedToken*(token: Token): bool {.inline.} =
  if token.kind == tkIdentifier:
    return not validIdentifier(token)
  if token.kind == tkString:
    return not isClosedString(token)
  false

proc isRoutineKind*(kind: SourceSymbolKind): bool {.inline.} =
  kind in {
    symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolMacro, symbolTemplate,
    symbolConverter,
  }

proc isRoutineKeyword*(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleRoutine)

proc isBlockKeyword*(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleBlock)

proc pushDelimiter*(
    stack: var seq[char], tokens: TokenStore, token: Token
): bool {.inline.} =
  if tokens.tokenTextLen(token) != 1 or
      not isOpeningDelimiter(tokens.tokenTextChar(token, 0)):
    return false
  stack.add tokens.tokenTextChar(token, 0)
  true

proc popDelimiter*(
    stack: var seq[char], tokens: TokenStore, token: Token
): bool {.inline.} =
  if tokens.tokenTextLen(token) != 1 or
      not isClosingDelimiter(tokens.tokenTextChar(token, 0)) or stack.len == 0:
    return false
  if not matchingDelimiter(stack[^1], tokens.tokenTextChar(token, 0)):
    return false
  stack.setLen(stack.len - 1)
  true
