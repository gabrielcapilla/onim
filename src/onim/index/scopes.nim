import std/algorithm

import ../syntax/tokens
import ../syntax/parser
import ./scope_lexing
import ./scope_syntax
import ./scope_uncertainty
import ./symbols

type
  ScopeId* = distinct uint32

  ScopeKind* = enum
    scopeModule
    scopeRoutine
    scopeBlock

  ScopeInterval* = object
    parent*: ScopeId
    kind*: ScopeKind
    ownerSymbol*: uint32
    firstToken*: uint32
    pastToken*: uint32
    startOffset*: int
    endOffset*: int

  LexicalDeclarationKind* = enum
    declarationParameter
    declarationLet
    declarationVar
    declarationConst

  LexicalDeclaration* = object
    scope*: ScopeId
    kind*: LexicalDeclarationKind
    nameToken*: uint32
    firstToken*: uint32
    pastToken*: uint32

  ScopeIndex* = object
    ## Numeric intervals and declaration spans reconstructed from tokens.
    scopes*: seq[ScopeInterval]
    declarations*: seq[LexicalDeclaration]
    uncertainty*: set[ScopeUncertainty]

const
  InvalidScopeId* = ScopeId(0)
  invalidScopeOwner* = high(uint32)

proc `==`*(left, right: ScopeId): bool {.borrow.}

proc scopeOrdinal*(scope: ScopeId): int {.inline.} =
  int(uint32(scope)) - 1

proc declarationGroup(
    tokens: TokenStore,
    first, last: int,
    scope: ScopeId,
    kind: LexicalDeclarationKind,
    declarations: var seq[LexicalDeclaration],
): bool {.gcsafe.} =
  if first >= last:
    return true
  var split = -1
  var delimiters: seq[char] = @[]
  for index in first ..< last:
    let token = tokens[index]
    if pushDelimiter(delimiters, tokens, token):
      continue
    if tokens.tokenTextLen(token) == 1 and
        tokens.tokenTextChar(token, 0) in {')', ']', '}'}:
      if not popDelimiter(delimiters, tokens, token):
        return false
      continue
    if delimiters.len == 0 and
        (tokens.tokenTextEquals(token, ":") or tokens.tokenTextEquals(token, "=")):
      split = index
      break
  if split < 0:
    return false

  var expectedName = true
  var names = 0
  for index in first ..< split:
    let token = tokens[index]
    if tokens.tokenTextEquals(token, ","):
      expectedName = true
    elif token.kind == tkIdentifier and not isValidNimKeyword(token):
      if not expectedName:
        return false
      declarations.add LexicalDeclaration(
        scope: scope,
        kind: kind,
        nameToken: uint32(index),
        firstToken: uint32(first),
        pastToken: uint32(last),
      )
      expectedName = false
      inc names
    elif token.isKeyword(kwVar) or token.isKeyword(kwOut) or
        tokens.tokenTextEquals(token, "sink") or tokens.tokenTextEquals(token, "lent"):
      discard
    else:
      return false
  if names == 0 or expectedName:
    return false

  delimiters.setLen(0)
  for index in split + 1 ..< last:
    let token = tokens[index]
    if pushDelimiter(delimiters, tokens, token):
      continue
    if tokens.tokenTextLen(token) == 1 and
        tokens.tokenTextChar(token, 0) in {')', ']', '}'}:
      if not popDelimiter(delimiters, tokens, token):
        return false
      continue
    if delimiters.len == 0 and tokens.tokenTextEquals(token, ":"):
      return false
  delimiters.len == 0

proc loopDeclarationGroup(
    tokens: TokenStore,
    first, last: int,
    scope: ScopeId,
    declarations: var seq[LexicalDeclaration],
): bool {.gcsafe.} =
  if first >= last:
    return false
  var expectedName = true
  var names = 0
  for index in first ..< last:
    let token = tokens[index]
    if tokens.tokenTextEquals(token, ","):
      expectedName = true
    elif token.kind == tkIdentifier and not isValidNimKeyword(token):
      if not expectedName:
        return false
      declarations.add LexicalDeclaration(
        scope: scope,
        kind: declarationParameter,
        nameToken: uint32(index),
        firstToken: uint32(first),
        pastToken: uint32(last),
      )
      expectedName = false
      inc names
    else:
      return false
  names > 0 and not expectedName

proc parameters(
    tokens: TokenStore,
    opening, closing: int,
    scope: ScopeId,
    declarations: var seq[LexicalDeclaration],
): bool {.gcsafe.} =
  if opening < 0 or closing <= opening:
    return true
  let before = declarations.len
  var first = opening + 1
  var delimiters: seq[char] = @[]
  var cursor = first
  while cursor < closing:
    let token = tokens[cursor]
    if pushDelimiter(delimiters, tokens, token):
      inc cursor
      continue
    if tokens.tokenTextLen(token) == 1 and
        tokens.tokenTextChar(token, 0) in {')', ']', '}'}:
      if not popDelimiter(delimiters, tokens, token):
        declarations.setLen(before)
        return false
    elif delimiters.len == 0 and tokens.tokenTextEquals(token, ";"):
      if not declarationGroup(
        tokens, first, cursor, scope, declarationParameter, declarations
      ):
        declarations.setLen(before)
        return false
      first = cursor + 1
    inc cursor
  if not declarationGroup(
    tokens, first, closing, scope, declarationParameter, declarations
  ):
    declarations.setLen(before)
    return false
  true

proc blockScopeStartingAt(
    index: ScopeIndex, token: uint32
): ScopeId {.inline, gcsafe.} =
  for ordinal, scope in index.scopes:
    if scope.kind == scopeBlock and scope.firstToken == token:
      return ScopeId(uint32(ordinal + 1))

proc appendBlockScope(
    tokens: TokenStore,
    routineScope: ScopeId,
    first, past, byteLength: int,
    scopeIndex: var ScopeIndex,
) {.gcsafe.} =
  var parent = routineScope
  for ordinal, candidate in scopeIndex.scopes:
    if candidate.kind != scopeBlock or candidate.firstToken >= uint32(first) or
        candidate.pastToken < uint32(past):
      continue
    let parentOrdinal = int(uint32(parent)) - 1
    if parentOrdinal < 0 or
        candidate.firstToken >= scopeIndex.scopes[parentOrdinal].firstToken:
      parent = ScopeId(uint32(ordinal + 1))
  scopeIndex.scopes.add ScopeInterval(
    parent: parent,
    kind: scopeBlock,
    ownerSymbol: invalidScopeOwner,
    firstToken: uint32(first),
    pastToken: uint32(past),
    startOffset: tokens[first].startOffset,
    endOffset: routineBodyEnd(tokens, past, byteLength),
  )

proc addBlockScopes(
    tokens: TokenStore,
    syntax: PartialSyntaxTree,
    routineScope: ScopeId,
    byteLength: int,
    scopeIndex: var ScopeIndex,
): bool {.gcsafe.} =
  if not syntax.syntaxAllowsBlocks:
    return false
  let routineOrdinal = int(uint32(routineScope)) - 1
  if routineOrdinal < 0 or routineOrdinal >= scopeIndex.scopes.len:
    return false
  let routine = scopeIndex.scopes[routineOrdinal]
  for node in syntax.nodes:
    if node.kind != syntaxBlock or node.firstToken <= routine.firstToken or
        node.pastToken > routine.pastToken:
      continue
    let first = int(node.firstToken)
    let past = int(node.pastToken)
    if first < 0 or first + 1 >= tokens.len or past <= first + 1 or past > tokens.len or
        not tokens.tokenTextEquals(tokens[first + 1], ":") or
        tokens[first + 1].line != tokens[first].line:
      scopeIndex.uncertainty.incl scopeNestedBlock
      continue
    let body = first + 2
    if body >= past or tokens[body].line <= tokens[first].line or
        tokens[body].column <= tokens[first].column:
      scopeIndex.uncertainty.incl scopeNestedBlock
      continue

    appendBlockScope(tokens, routineScope, first, past, byteLength, scopeIndex)

  var index = int(routine.firstToken)
  while index < int(routine.pastToken):
    if tokens[index].isKeyword(kwFor):
      let past = blockEnd(tokens, index)
      if past > index + 1 and past <= int(routine.pastToken):
        appendBlockScope(tokens, routineScope, index, past, byteLength, scopeIndex)
    inc index
  true

proc locals(
    tokens: TokenStore,
    bounds: tuple[first, past, baseColumn: int, valid: bool],
    scope: ScopeId,
    declarations: var seq[LexicalDeclaration],
    result: var ScopeIndex,
) {.gcsafe.} =
  if not bounds.valid:
    return
  var index = bounds.first
  while index < bounds.past:
    let token = tokens[index]
    if token.kind == tkIdentifier and not isStropped(token) and token.isKeyword(kwFor):
      let nestedScope = result.blockScopeStartingAt(uint32(index))
      if nestedScope != InvalidScopeId:
        let headerEnd = loopHeaderEnd(tokens, index + 1, bounds.past)
        let before = declarations.len
        if headerEnd <= index + 1 or
            not loopDeclarationGroup(
              tokens, index + 1, headerEnd, nestedScope, declarations
            ):
          declarations.setLen(before)
          result.uncertainty.incl scopeNestedBlock
    if token.kind == tkIdentifier and not isStropped(token) and isBlockKeyword(token):
      let nestedScope = result.blockScopeStartingAt(uint32(index))
      if nestedScope != InvalidScopeId:
        index =
          max(index + 1, int(result.scopes[int(uint32(nestedScope)) - 1].pastToken))
        continue
      result.uncertainty.incl scopeNestedBlock
    if token.kind == tkIdentifier and not isStropped(token) and
        token.hasKeywordRole(roleValueDeclaration):
      if not statementStart(tokens, index, bounds.first, bounds.baseColumn) or
          token.column != bounds.baseColumn:
        result.uncertainty.incl scopeNestedBlock
        inc index
        continue
      let kind =
        case token.keywordOf
        of kwLet: declarationLet
        of kwVar: declarationVar
        else: declarationConst
      let finish = localDeclarationEnd(tokens, index, bounds.past, bounds.baseColumn)
      let before = declarations.len
      if not declarationGroup(tokens, index + 1, finish, scope, kind, declarations):
        declarations.setLen(before)
        result.uncertainty.incl scopeUnsupportedDeclaration
      index = max(index + 1, finish)
      continue
    if tokens[index].line > tokens[bounds.first].line and
        tokens[index].column > bounds.baseColumn and
        (index == bounds.first or tokens[index].line != tokens[index - 1].line):
      result.uncertainty.incl scopeNestedBlock
    inc index

proc indexedRoutine(
    tokens: TokenStore,
    symbol: SourceSymbol,
    symbolIndex: int,
    byteLength: int,
    syntax: PartialSyntaxTree,
    result: var ScopeIndex,
) {.gcsafe.} =
  let nameToken = int(symbol.nameToken)
  let header = routineHeader(tokens, nameToken)
  if not header.valid:
    result.uncertainty.incl scopeUnsupportedHeader
    return
  if not header.hasBody:
    if header.equals >= 0:
      result.uncertainty.incl scopeUnsupportedHeader
    return
  if header.opening < 0 or header.closing < 0 or
      tokens[header.opening].line != tokens[header.closing].line:
    result.uncertainty.incl scopeUnsupportedHeader
    return

  for index in nameToken + 1 ..< header.opening:
    if tokens.tokenTextEquals(tokens[index], "["):
      result.uncertainty.incl scopeUnsupportedHeader
      return
  for index in header.closing + 1 ..< header.equals:
    if tokens.tokenTextEquals(tokens[index], "{"):
      result.uncertainty.incl scopeUnsupportedHeader
      return

  let bounds = bodyBounds(tokens, header.equals)
  if not bounds.valid:
    result.uncertainty.incl scopeUnsupportedHeader
    return
  if bounds.past <= header.start or bounds.past > tokens.len:
    result.uncertainty.incl scopeMalformed
    return

  let scope = ScopeId(uint32(result.scopes.len + 1))
  result.scopes.add ScopeInterval(
    parent: ScopeId(1),
    kind: scopeRoutine,
    ownerSymbol: uint32(symbolIndex),
    firstToken: uint32(header.start),
    pastToken: uint32(bounds.past),
    startOffset: tokens[header.start].startOffset,
    endOffset: routineBodyEnd(tokens, bounds.past, byteLength),
  )
  let before = result.declarations.len
  if not parameters(tokens, header.opening, header.closing, scope, result.declarations):
    result.declarations.setLen(before)
    result.uncertainty.incl scopeUnsupportedHeader
  discard addBlockScopes(tokens, syntax, scope, byteLength, result)
  locals(tokens, bounds, scope, result.declarations, result)
  for ordinal in 1 ..< result.scopes.len:
    if result.scopes[ordinal].kind != scopeBlock or
        result.scopes[ordinal].firstToken < uint32(bounds.first) or
        result.scopes[ordinal].pastToken > uint32(bounds.past):
      continue
    let blockScope = result.scopes[ordinal]
    let blockFirst = int(blockScope.firstToken) + 2
    let blockPast = int(blockScope.pastToken)
    if blockFirst >= blockPast or blockFirst >= tokens.len:
      result.uncertainty.incl scopeNestedBlock
      continue
    locals(
      tokens,
      (
        first: blockFirst,
        past: blockPast,
        baseColumn: tokens[blockFirst].column,
        valid: true,
      ),
      ScopeId(uint32(ordinal + 1)),
      result.declarations,
      result,
    )

proc indexScopes*(
    tokens: TokenStore,
    symbols: openArray[SourceSymbol],
    byteLength: int,
    syntax: PartialSyntaxTree,
): ScopeIndex {.gcsafe.} =
  result.scopes.add ScopeInterval(
    parent: InvalidScopeId,
    kind: scopeModule,
    ownerSymbol: invalidScopeOwner,
    firstToken: 0,
    pastToken: uint32(tokens.len),
    startOffset: 0,
    endOffset: byteLength,
  )
  markMalformed(tokens, result.uncertainty)
  markGlobalUncertainty(tokens, result.uncertainty)

  for symbolIndex, symbol in symbols:
    if isRoutineKind(symbol.kind):
      indexedRoutine(tokens, symbol, symbolIndex, byteLength, syntax, result)

  result.scopes.sort(
    proc(left, right: ScopeInterval): int =
      if left.kind == scopeModule:
        return -1
      if right.kind == scopeModule:
        return 1
      cmp(left.firstToken, right.firstToken)
  )
  result.declarations.sort(
    proc(left, right: LexicalDeclaration): int =
      cmp(left.nameToken, right.nameToken)
  )

proc indexScopes*(
    tokens: TokenStore, symbols: openArray[SourceSymbol], byteLength: int
): ScopeIndex {.gcsafe.} =
  let syntax = parsePartialSyntax(tokens)
  indexScopes(tokens, symbols, byteLength, syntax)

proc innermostScopeAt*(index: ScopeIndex, token: uint32): ScopeId =
  for ordinal, scope in index.scopes:
    if token >= scope.firstToken and token < scope.pastToken:
      if result == InvalidScopeId:
        result = ScopeId(uint32(ordinal + 1))
      elif scope.firstToken >= index.scopes[int(uint32(result)) - 1].firstToken:
        result = ScopeId(uint32(ordinal + 1))
