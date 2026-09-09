import ../index/symbols
import ../syntax/tokens

proc routineHasBody*(tokens: TokenStore, symbol: SourceSymbol): bool =
  let nameIndex = int(symbol.nameToken)
  if nameIndex < 0 or nameIndex + 1 >= tokens.len:
    return false
  var nesting = 0
  for cursor in nameIndex + 1 ..< tokens.len:
    if cursor > nameIndex + 1 and tokens[cursor].line > tokens[nameIndex].line and
        tokens[cursor].column == 0:
      break
    if tokens.tokenTextEquals(tokens[cursor], "(") or
        tokens.tokenTextEquals(tokens[cursor], "[") or
        tokens.tokenTextEquals(tokens[cursor], "{"):
      inc nesting
    elif tokens.tokenTextEquals(tokens[cursor], ")") or
        tokens.tokenTextEquals(tokens[cursor], "]") or
        tokens.tokenTextEquals(tokens[cursor], "}"):
      if nesting > 0:
        dec nesting
    elif tokens.tokenTextEquals(tokens[cursor], "="):
      if nesting == 0:
        return true
  false
