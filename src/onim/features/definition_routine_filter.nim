import ../index/scope_lexing
import ../index/source_index
import ../index/symbols
import ../syntax/tokens
import ./ufcs_arity

proc routineKind*(kind: SourceSymbolKind): bool =
  kind in {
    symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolMacro, symbolTemplate,
    symbolConverter,
  }

proc filterRoutineMatches*(
    index: SourceIndex, matches: seq[int], callTokens: TokenStore, tokenIndex: int
): seq[int] =
  if index == nil or matches.len <= 1 or tokenIndex < 0:
    return matches
  let call = ufcsCallArity(callTokens, tokenIndex)
  if call.kind != ufcsCallKnown:
    return matches
  for symbolIndex in matches:
    if symbolIndex < 0 or symbolIndex >= index.symbols.len:
      return matches
    let symbol = index.symbols[symbolIndex]
    if not isRoutineKind(symbol.kind):
      return matches
    let arity = routineFormalArity(index.parsed.tokens, index.scopes, symbolIndex)
    if arity.kind != ufcsArityFixed:
      return matches
    if arity.count == call.count:
      result.add symbolIndex
  if result.len == 0:
    return matches
