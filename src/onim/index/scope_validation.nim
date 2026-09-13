import ../syntax/tokens
import ./scope_lexing
import ./scope_syntax
import ./scopes
import ./symbols

proc containsToken(scope: ScopeInterval, token: uint32): bool {.inline.} =
  token >= scope.firstToken and token < scope.pastToken

proc scopeContains(index: ScopeIndex, scope: ScopeId, token: uint32): bool =
  let ordinal = int(uint32(scope)) - 1
  ordinal >= 0 and ordinal < index.scopes.len and
    index.scopes[ordinal].containsToken(token)

proc validateScopes*(
    index: ScopeIndex,
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    byteLength: int,
): bool =
  if byteLength < 0 or index.scopes.len == 0:
    return false
  let root = index.scopes[0]
  if root.parent != InvalidScopeId or root.kind != scopeModule or
      root.ownerSymbol != invalidScopeOwner or root.firstToken != 0 or
      root.pastToken != uint32(tokens.len) or root.startOffset != 0 or
      root.endOffset != byteLength:
    return false

  for ordinal, scope in index.scopes:
    if scope.firstToken > scope.pastToken or scope.pastToken > uint32(tokens.len) or
        scope.startOffset < 0 or scope.startOffset > scope.endOffset or
        scope.endOffset > byteLength:
      return false
    # The module extent includes leading and trailing trivia.
    if ordinal > 0 and scope.firstToken < uint32(tokens.len) and
        scope.startOffset != tokens[int(scope.firstToken)].startOffset:
      return false
    if ordinal > 0 and scope.pastToken < uint32(tokens.len) and
        scope.endOffset != tokens[int(scope.pastToken)].startOffset:
      return false
    if ordinal == 0:
      continue
    let parentOrdinal = int(uint32(scope.parent)) - 1
    if parentOrdinal < 0 or parentOrdinal >= ordinal or
        not index.scopes[parentOrdinal].containsToken(scope.firstToken) or
        scope.pastToken > index.scopes[parentOrdinal].pastToken:
      return false
    case scope.kind
    of scopeRoutine:
      if scope.ownerSymbol >= uint32(symbols.len):
        return false
      let owner = symbols[int(scope.ownerSymbol)]
      if not isRoutineKind(owner.kind) or not scope.containsToken(owner.nameToken):
        return false
    of scopeBlock:
      if scope.ownerSymbol != invalidScopeOwner or parentOrdinal == 0 or
          index.scopes[parentOrdinal].kind notin {scopeRoutine, scopeBlock}:
        return false
      let first = int(scope.firstToken)
      if first >= tokens.len:
        return false
      if tokens.tokenTextEquals(tokens[first], "block"):
        if first + 1 >= tokens.len or not tokens.tokenTextEquals(tokens[first + 1], ":"):
          return false
      elif tokens[first].isKeyword(kwFor):
        if loopHeaderEnd(tokens, first + 1, int(scope.pastToken)) <= first + 1:
          return false
      else:
        return false
    else:
      return false

  for leftIndex in 1 ..< index.scopes.len:
    let left = index.scopes[leftIndex]
    for rightIndex in leftIndex + 1 ..< index.scopes.len:
      let right = index.scopes[rightIndex]
      let overlap =
        left.firstToken < right.pastToken and right.firstToken < left.pastToken
      if overlap and
          not (
            left.containsToken(right.firstToken) or right.containsToken(left.firstToken)
          ):
        return false

  var previousScopeStart = uint32(0)
  for ordinal in 1 ..< index.scopes.len:
    if ordinal > 1 and index.scopes[ordinal].firstToken <= previousScopeStart:
      return false
    previousScopeStart = index.scopes[ordinal].firstToken

  var declarationTokens = newSeq[bool](tokens.len)
  var previousName = high(uint32)
  for declaration in index.declarations:
    if declaration.scope == InvalidScopeId or
        not scopeContains(index, declaration.scope, declaration.nameToken) or
        declaration.firstToken > declaration.nameToken or
        declaration.nameToken >= declaration.pastToken or
        declaration.pastToken > uint32(tokens.len) or
        tokens[int(declaration.nameToken)].kind != tkIdentifier or
        isValidNimKeyword(tokens[int(declaration.nameToken)]) or
        (previousName != high(uint32) and declaration.nameToken <= previousName) or
        declarationTokens[int(declaration.nameToken)]:
      return false
    let declarationOrdinal = int(uint32(declaration.scope)) - 1
    if declarationOrdinal < 0 or declarationOrdinal >= index.scopes.len or
        declaration.pastToken > index.scopes[declarationOrdinal].pastToken:
      return false
    declarationTokens[int(declaration.nameToken)] = true
    previousName = declaration.nameToken
  true
