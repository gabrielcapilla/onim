import ../syntax/tokens
import ../syntax/parser
import ./scope_lexing

proc loopHeaderEnd*(tokens: TokenStore, first, past: int): int {.inline.} =
  for index in first ..< past:
    if tokens[index].isKeyword(kwIn):
      return index
  -1

proc matchingParen(
    tokens: TokenStore, opening: int
): tuple[closing: int, valid: bool] {.gcsafe.} =
  var stack: seq[char] = @[]
  for index in opening ..< tokens.len:
    let token = tokens[index]
    if pushDelimiter(stack, tokens, token):
      continue
    if tokens.tokenTextLen(token) == 1 and
        tokens.tokenTextChar(token, 0) in {')', ']', '}'}:
      if not popDelimiter(stack, tokens, token):
        return (-1, false)
      if stack.len == 0:
        return (index, true)
  (-1, false)

proc routineHeader*(
    tokens: TokenStore, nameToken: int
): tuple[start, opening, closing, equals: int, valid, hasBody: bool] {.gcsafe.} =
  result.start = nameToken - 1
  result.opening = -1
  result.closing = -1
  result.equals = -1
  if nameToken <= 0 or nameToken >= tokens.len or result.start < 0 or
      tokens[result.start].column != 0 or not isRoutineKeyword(tokens[result.start]):
    return

  var cursor = nameToken + 1
  while cursor < tokens.len:
    if tokens.tokenTextEquals(tokens[cursor], "("):
      result.opening = cursor
      break
    if tokens.tokenTextEquals(tokens[cursor], "="):
      result.equals = cursor
      result.valid = true
      result.hasBody = tokens[cursor].line == tokens[result.start].line
      return
    if tokens.tokenTextEquals(tokens[cursor], ";") or
        (tokens[cursor].line > tokens[result.start].line and tokens[cursor].column == 0):
      result.valid = true
      return
    inc cursor
  if result.opening < 0:
    result.valid = true
    return

  let matched = matchingParen(tokens, result.opening)
  if not matched.valid:
    return
  result.closing = matched.closing
  result.valid = true

  cursor = result.closing + 1
  var depth = 0
  while cursor < tokens.len:
    if tokens.tokenTextEquals(tokens[cursor], "(") or
        tokens.tokenTextEquals(tokens[cursor], "[") or
        tokens.tokenTextEquals(tokens[cursor], "{"):
      inc depth
    elif tokens.tokenTextEquals(tokens[cursor], ")") or
        tokens.tokenTextEquals(tokens[cursor], "]") or
        tokens.tokenTextEquals(tokens[cursor], "}"):
      if depth == 0:
        return
      dec depth
    elif tokens.tokenTextEquals(tokens[cursor], "=") and depth == 0:
      result.equals = cursor
      break
    elif tokens.tokenTextEquals(tokens[cursor], ";") and depth == 0:
      break
    elif tokens[cursor].line > tokens[result.start].line and tokens[cursor].column == 0 and
        depth == 0:
      break
    inc cursor

  if result.equals < 0:
    if cursor > result.closing + 1 or (
      cursor < tokens.len and tokens[cursor].line == tokens[result.start].line and
      not tokens.tokenTextEquals(tokens[cursor], ";")
    ):
      result.valid = false
    return
  result.hasBody = tokens[result.equals].line == tokens[result.start].line

proc bodyBounds*(
    tokens: TokenStore, equals: int
): tuple[first, past, baseColumn: int, valid: bool] {.gcsafe.} =
  if equals < 0 or equals + 1 >= tokens.len:
    return
  result.first = equals + 1
  result.baseColumn = tokens[result.first].column
  if tokens[result.first].line > tokens[equals].line and result.baseColumn <= 0:
    return
  var delimiters: seq[char] = @[]
  result.past = result.first
  while result.past < tokens.len:
    let token = tokens[result.past]
    if pushDelimiter(delimiters, tokens, token):
      inc result.past
      continue
    if tokens.tokenTextLen(token) == 1 and
        isClosingDelimiter(tokens.tokenTextChar(token, 0)):
      if not popDelimiter(delimiters, tokens, token):
        return
      inc result.past
      continue
    if delimiters.len == 0 and result.past > result.first and
        token.line > tokens[equals].line and token.column == 0:
      break
    inc result.past
  result.valid = result.past > result.first and delimiters.len == 0

proc statementStart*(
    tokens: TokenStore, index, first, baseColumn: int
): bool {.gcsafe.} =
  if index == first:
    return true
  if tokens.tokenTextEquals(tokens[index], ";"):
    return false
  if tokens.tokenTextEquals(tokens[index - 1], ";"):
    return true
  tokens[index].line != tokens[index - 1].line and tokens[index].column == baseColumn

proc localDeclarationEnd*(
    tokens: TokenStore, start, past, baseColumn: int
): int {.gcsafe.} =
  result = start + 1
  var delimiters: seq[char] = @[]
  while result < past:
    let token = tokens[result]
    if pushDelimiter(delimiters, tokens, token):
      inc result
      continue
    if tokens.tokenTextLen(token) == 1 and
        isClosingDelimiter(tokens.tokenTextChar(token, 0)):
      if not popDelimiter(delimiters, tokens, token):
        inc result
        continue
      inc result
      continue
    if delimiters.len == 0 and tokens.tokenTextEquals(token, ";"):
      break
    if delimiters.len == 0 and token.line > tokens[start].line and
        token.column <= baseColumn:
      break
    inc result

proc syntaxAllowsBlocks*(tree: PartialSyntaxTree): bool {.gcsafe.} =
  if not tree.validateSyntaxTree:
    return false
  for reason in tree.uncertainty:
    case reason
    of parserMalformed, parserUnbalanced, parserIncomplete, parserUnsupportedStructure:
      return false
    of parserNestedDeclaration:
      discard
  true

proc routineBodyEnd*(tokens: TokenStore, past, byteLength: int): int {.gcsafe.} =
  if past >= tokens.len:
    return byteLength
  tokens[past].startOffset
