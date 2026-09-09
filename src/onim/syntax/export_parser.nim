import ./statement_ranges
import ./tokens

proc exportNameToken(tokens: TokenStore, index: int): bool {.inline.} =
  index >= 0 and index < tokens.len and tokens[index].kind == tkIdentifier and
    tokens[index].validIdentifier and not tokens[index].isStropped and
    not tokens[index].isNimKeyword

proc parseExportNames*(
    tokens: TokenStore, index: int
): tuple[names: seq[string], next: int, uncertainty: set[StatementUncertainty]] =
  let statement = statementRange(tokens, index)
  let endIndex = statement.past
  result.next = endIndex
  result.uncertainty = statement.uncertainty
  if statementHasMissingOperand(tokens, index, endIndex):
    result.uncertainty.incl statementIncomplete
    return
  var cursor = index + 1
  while cursor < endIndex:
    if not exportNameToken(tokens, cursor):
      result.names.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    result.names.add tokens.tokenText(tokens[cursor])
    inc cursor
    if cursor >= endIndex:
      break
    if not tokens.tokenTextEquals(tokens[cursor], ","):
      result.names.setLen(0)
      result.uncertainty.incl statementUnsupported
      return
    inc cursor
    if cursor >= endIndex:
      result.names.setLen(0)
      result.uncertainty.incl statementIncomplete
      return
