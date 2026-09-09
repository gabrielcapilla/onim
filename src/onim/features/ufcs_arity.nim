import ../index/scopes
import ../index/scope_uncertainty
import ../syntax/tokens

type
  UfcsFormalArityKind* = enum
    ufcsArityUnknown
    ufcsArityFixed
    ufcsArityVariable

  UfcsCallKind* = enum
    ufcsNotCall
    ufcsCallKnown
    ufcsCallUncertain

proc formalArityForScope*(
    tokens: TokenStore, scopes: ScopeIndex, scope: ScopeId
): tuple[kind: UfcsFormalArityKind, count: uint32] =
  result.kind = ufcsArityUnknown
  if scope == InvalidScopeId:
    return
  let scopeOrdinal = int(uint32(scope)) - 1
  if scopeOrdinal < 0 or scopeOrdinal >= scopes.scopes.len or
      scopes.scopes[scopeOrdinal].kind != scopeRoutine or
      scopeUnsupportedHeader in scopes.uncertainty:
    return
  for declaration in scopes.declarations:
    if declaration.scope != scope or declaration.kind != declarationParameter:
      continue
    if declaration.firstToken >= declaration.pastToken or
        declaration.pastToken > uint32(tokens.len):
      return
    inc result.count
    var delimiters: seq[char] = @[]
    for tokenIndex in int(declaration.firstToken) ..< int(declaration.pastToken):
      let token = tokens[tokenIndex]
      if token.kind == tkPunctuation and tokens.tokenTextLen(token) == 1:
        let value = tokens.tokenTextChar(token, 0)
        if isOpeningDelimiter(value):
          delimiters.add value
          continue
        if isClosingDelimiter(value):
          if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
            return
          delimiters.setLen(delimiters.len - 1)
          continue
        if delimiters.len == 0 and value == '=':
          result.kind = ufcsArityVariable
          return
      if delimiters.len == 0 and tokens.tokenTextEquals(token, "varargs"):
        result.kind = ufcsArityVariable
        return
    if delimiters.len > 0:
      return
  result.kind = ufcsArityFixed

proc ufcsFormalArity*(
    tokens: TokenStore, scopes: ScopeIndex, first: LexicalDeclaration
): tuple[kind: UfcsFormalArityKind, count: uint32] =
  if first.kind != declarationParameter:
    return
  formalArityForScope(tokens, scopes, first.scope)

proc routineFormalArity*(
    tokens: TokenStore, scopes: ScopeIndex, symbolIndex: int
): tuple[kind: UfcsFormalArityKind, count: uint32] =
  if symbolIndex < 0 or symbolIndex > int(high(uint32)):
    return
  for ordinal, scope in scopes.scopes:
    if scope.kind == scopeRoutine and scope.ownerSymbol == uint32(symbolIndex):
      return formalArityForScope(tokens, scopes, ScopeId(uint32(ordinal + 1)))

proc ufcsCallArity*(
    tokens: TokenStore, memberToken: int
): tuple[kind: UfcsCallKind, count: uint32] =
  if memberToken < 0 or memberToken + 1 >= tokens.len or
      not tokens.tokenTextEquals(tokens[memberToken + 1], "("):
    result.kind = ufcsNotCall
    return
  result.kind = ufcsCallUncertain
  var delimiters = @['(']
  var hasArgument = false
  for tokenIndex in memberToken + 2 ..< tokens.len:
    let token = tokens[tokenIndex]
    if token.kind == tkPunctuation and tokens.tokenTextLen(token) == 1:
      let value = tokens.tokenTextChar(token, 0)
      if isOpeningDelimiter(value):
        delimiters.add value
        hasArgument = true
        continue
      if isClosingDelimiter(value):
        if delimiters.len == 0 or not matchingDelimiter(delimiters[^1], value):
          return
        delimiters.setLen(delimiters.len - 1)
        if delimiters.len == 0:
          if hasArgument:
            inc result.count
          elif result.count > 0:
            return
          result.kind = ufcsCallKnown
          return
        continue
      if delimiters.len == 1 and value == ',':
        if not hasArgument:
          return
        inc result.count
        hasArgument = false
        continue
    if delimiters.len == 1:
      hasArgument = true
