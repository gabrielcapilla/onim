import ./module_names
import ./tokens

type
  StatementUncertainty* = enum
    statementIncomplete
    statementUnbalanced
    statementUnsupported

  StatementRange* = object
    past*: int
    uncertainty*: set[StatementUncertainty]

proc isModuleStatementStart*(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleImport) or token.hasKeywordRole(roleFrom) or
    token.hasKeywordRole(roleInclude) or token.hasKeywordRole(roleExport)

proc statementRange*(tokens: TokenStore, start: int): StatementRange =
  result.past = min(tokens.len, start + 1)
  if start < 0 or start >= tokens.len:
    return
  var index = start + 1
  var delimiters: seq[char] = @[]
  while index < tokens.len:
    if delimiters.len > 0 and tokens[index].line > tokens[start].line and
        tokens[index].column <= tokens[start].column and
        tokens[index].isModuleStatementStart:
      result.uncertainty.incl statementIncomplete
      result.past = index
      return

    let value =
      if tokens.tokenTextLen(tokens[index]) == 1:
        tokens.tokenTextChar(tokens[index], 0)
      else:
        '\0'
    if isOpeningDelimiter(value):
      delimiters.add value
    elif isClosingDelimiter(value):
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
        result.uncertainty.incl statementUnbalanced
      else:
        delimiters.setLen(delimiters.len - 1)
    elif tokens.tokenTextEquals(tokens[index], ";") and delimiters.len == 0:
      result.past = index
      return
    elif delimiters.len == 0 and tokens[index].line > tokens[start].line:
      if index == start + 1 or (
        not tokens.tokenTextEquals(tokens[index - 1], ",") and
        not tokens.tokenTextEquals(tokens[index - 1], "/") and
        not tokens.tokenTextEquals(tokens[index - 1], ".") and
        not tokens.tokenTextEquals(tokens[index - 1], "\\")
      ):
        result.past = index
        return
    inc index
  result.past = index
  if delimiters.len > 0:
    result.uncertainty.incl statementIncomplete

proc statementHasMissingOperand*(tokens: TokenStore, start, past: int): bool =
  if start < 0 or past <= start + 1 or past > tokens.len:
    return true
  let last = tokens[past - 1]
  if last.isKeyword(kwAs) or last.isKeyword(kwExcept) or last.isKeyword(kwImport):
    return true
  if tokens.tokenTextLen(last) != 1:
    return false
  tokens.tokenTextChar(last, 0) in {',', '/', '.', '\\', '[', '(', '{'}

proc fromStatementComplete*(tokens: TokenStore, start, past: int): bool =
  var importIndex = start + 1
  while importIndex < past and not tokens[importIndex].isKeyword(kwImport):
    inc importIndex
  importIndex > start + 1 and importIndex < past and
    not statementHasMissingOperand(tokens, start, past) and
    moduleText(tokens, start + 1, importIndex).len > 0
