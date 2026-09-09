import ../index/scope_lexing
import ../index/source_index
import ../syntax/tokens
import ./routine_body

proc completeSymbol*(index: SourceIndex, symbolIndex: int): bool =
  if index == nil or symbolIndex < 0 or symbolIndex >= index.symbols.len:
    return false
  let symbol = index.symbols[symbolIndex]
  if int(symbol.nameToken) >= index.parsed.tokens.len:
    return false
  not isRoutineKind(symbol.kind) or routineHasBody(index.parsed.tokens, symbol)
