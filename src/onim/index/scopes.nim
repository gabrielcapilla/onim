import std/[algorithm, strutils]

import ../syntax/lexer
import ../syntax/parser
import ./symbols

type
  ScopeId* = distinct uint32

  ScopeKind* = enum
    scopeModule
    scopeRoutine
    scopeBlock

  ScopeUncertainty* = enum
    scopeUnsupportedHeader
    scopeUnsupportedDeclaration
    scopeNestedBlock
    scopeConditional
    scopeGenerated
    scopeInclude
    scopeMalformed

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
  invalidScopeOwner = high(uint32)

proc `==`*(left, right: ScopeId): bool {.borrow.}

proc malformedToken(token: Token): bool {.inline.} =
  if token.kind == tkIdentifier:
    return not validIdentifier(token)
  if token.kind == tkString:
    return not isClosedString(token)
  false

proc isRoutineKind(kind: SourceSymbolKind): bool {.inline.} =
  kind in {
    symbolProc, symbolFunc, symbolIterator, symbolMethod, symbolMacro, symbolTemplate,
    symbolConverter,
  }

proc isRoutineKeyword(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleRoutine)

proc isBlockKeyword(token: Token): bool {.inline.} =
  token.hasKeywordRole(roleBlock)

proc pushDelimiter(stack: var seq[char], text: string): bool {.inline.} =
  if text.len != 1 or not isOpeningDelimiter(text[0]):
    return false
  stack.add text[0]
  true

proc popDelimiter(stack: var seq[char], text: string): bool {.inline.} =
  if text.len != 1 or not isClosingDelimiter(text[0]) or stack.len == 0:
    return false
  if not matchingDelimiter(stack[^1], text[0]):
    return false
  stack.setLen(stack.len - 1)
  true

proc markMalformed[T](tokens: T, result: var ScopeIndex) =
  var delimiters: seq[char] = @[]
  for token in tokens:
    if malformedToken(token):
      result.uncertainty.incl scopeMalformed
    if token.kind != tkPunctuation:
      continue
    if pushDelimiter(delimiters, token.text):
      continue
    if token.text.len == 1 and isClosingDelimiter(token.text[0]) and
        not popDelimiter(delimiters, token.text):
      result.uncertainty.incl scopeMalformed
  if delimiters.len > 0:
    result.uncertainty.incl scopeMalformed

proc markGlobalUncertainty[T](tokens: T, result: var ScopeIndex) =
  for token in tokens:
    if token.kind != tkIdentifier or not validIdentifier(token) or isStropped(token):
      continue
    if token.hasKeywordRole(roleConditional):
      result.uncertainty.incl scopeConditional
    elif token.hasKeywordRole(roleInclude):
      result.uncertainty.incl scopeInclude
    elif token.hasKeywordRole(roleGenerated):
      result.uncertainty.incl scopeGenerated

proc matchingParen[T](tokens: T, opening: int): tuple[closing: int, valid: bool] =
  var stack: seq[char] = @[]
  for index in opening ..< tokens.len:
    let text = tokens[index].text
    if pushDelimiter(stack, text):
      continue
    if text.len == 1 and text[0] in {')', ']', '}'}:
      if not popDelimiter(stack, text):
        return (-1, false)
      if stack.len == 0:
        return (index, true)
  (-1, false)

proc routineHeader[T](
    tokens: T, nameToken: int
): tuple[start, opening, closing, equals: int, valid, hasBody: bool] =
  result.start = nameToken - 1
  result.opening = -1
  result.closing = -1
  result.equals = -1
  if nameToken <= 0 or nameToken >= tokens.len or result.start < 0 or
      tokens[result.start].column != 0 or not isRoutineKeyword(tokens[result.start]):
    return

  var cursor = nameToken + 1
  while cursor < tokens.len:
    if tokens[cursor].text == "(":
      result.opening = cursor
      break
    if tokens[cursor].text == "=":
      result.equals = cursor
      result.valid = true
      result.hasBody = tokens[cursor].line == tokens[result.start].line
      return
    if tokens[cursor].text == ";" or
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
    let text = tokens[cursor].text
    if text == "(" or text == "[" or text == "{":
      inc depth
    elif text == ")" or text == "]" or text == "}":
      if depth == 0:
        return
      dec depth
    elif text == "=" and depth == 0:
      result.equals = cursor
      break
    elif text == ";" and depth == 0:
      break
    elif tokens[cursor].line > tokens[result.start].line and tokens[cursor].column == 0 and
        depth == 0:
      break
    inc cursor

  if result.equals < 0:
    if cursor > result.closing + 1 or (
      cursor < tokens.len and tokens[cursor].line == tokens[result.start].line and
      tokens[cursor].text != ";"
    ):
      result.valid = false
    return
  result.hasBody = tokens[result.equals].line == tokens[result.start].line

proc declarationGroup[T](
    tokens: T,
    first, last: int,
    scope: ScopeId,
    kind: LexicalDeclarationKind,
    declarations: var seq[LexicalDeclaration],
): bool =
  if first >= last:
    return true
  var split = -1
  var delimiters: seq[char] = @[]
  for index in first ..< last:
    let text = tokens[index].text
    if pushDelimiter(delimiters, text):
      continue
    if text.len == 1 and text[0] in {')', ']', '}'}:
      if not popDelimiter(delimiters, text):
        return false
      continue
    if delimiters.len == 0 and (text == ":" or text == "="):
      split = index
      break
  if split < 0:
    return false

  var expectedName = true
  var names = 0
  for index in first ..< split:
    let token = tokens[index]
    if token.text == ",":
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
    elif token.isKeyword(kwVar) or token.isKeyword(kwOut) or token.text == "sink" or
        token.text == "lent":
      discard
    else:
      return false
  if names == 0 or expectedName:
    return false

  delimiters.setLen(0)
  for index in split + 1 ..< last:
    let text = tokens[index].text
    if pushDelimiter(delimiters, text):
      continue
    if text.len == 1 and text[0] in {')', ']', '}'}:
      if not popDelimiter(delimiters, text):
        return false
      continue
    if delimiters.len == 0 and text == ":":
      return false
  true

proc parameters[T](
    tokens: T,
    opening, closing: int,
    scope: ScopeId,
    declarations: var seq[LexicalDeclaration],
): bool =
  if opening < 0 or closing <= opening:
    return true
  let before = declarations.len
  var first = opening + 1
  var delimiters: seq[char] = @[]
  var cursor = first
  while cursor < closing:
    let text = tokens[cursor].text
    if pushDelimiter(delimiters, text):
      inc cursor
      continue
    if text.len == 1 and text[0] in {')', ']', '}'}:
      if not popDelimiter(delimiters, text):
        declarations.setLen(before)
        return false
    elif delimiters.len == 0 and text == ";":
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

proc bodyBounds[T](
    tokens: T, equals: int
): tuple[first, past, baseColumn: int, valid: bool] =
  if equals < 0 or equals + 1 >= tokens.len:
    return
  result.first = equals + 1
  result.baseColumn = tokens[result.first].column
  if tokens[result.first].line == tokens[equals].line:
    result.past = result.first
    while result.past < tokens.len and tokens[result.past].line == tokens[equals].line and
        tokens[result.past].text != ";":
      inc result.past
    result.valid = result.past > result.first
    return

  if result.baseColumn <= 0:
    return
  result.past = result.first
  while result.past < tokens.len:
    if result.past > result.first and tokens[result.past].line > tokens[equals].line and
        tokens[result.past].column == 0:
      break
    inc result.past
  result.valid = result.past > result.first

proc statementStart[T](tokens: T, index, first, baseColumn: int): bool =
  if index == first:
    return true
  if tokens[index].text == ";":
    return false
  if tokens[index - 1].text == ";":
    return true
  tokens[index].line != tokens[index - 1].line and tokens[index].column == baseColumn

proc localDeclarationEnd[T](tokens: T, start, past, baseColumn: int): int =
  result = start + 1
  while result < past:
    if tokens[result].text == ";":
      break
    if tokens[result].line > tokens[start].line and tokens[result].column <= baseColumn:
      break
    inc result

proc blockScopeStartingAt(index: ScopeIndex, token: uint32): ScopeId {.inline.} =
  for ordinal, scope in index.scopes:
    if scope.kind == scopeBlock and scope.firstToken == token:
      return ScopeId(uint32(ordinal + 1))

proc syntaxAllowsBlocks(tree: PartialSyntaxTree): bool =
  if not tree.validateSyntaxTree:
    return false
  for reason in tree.uncertainty:
    case reason
    of parserMalformed, parserUnbalanced, parserUnsupportedStructure:
      return false
    of parserNestedDeclaration:
      discard
  true

proc routineBodyEnd[T](tokens: T, past, byteLength: int): int

proc addBlockScopes[T](
    tokens: T,
    syntax: PartialSyntaxTree,
    routineScope: ScopeId,
    byteLength: int,
    scopeIndex: var ScopeIndex,
): bool =
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
        tokens[first + 1].text != ":" or tokens[first + 1].line != tokens[first].line:
      scopeIndex.uncertainty.incl scopeNestedBlock
      continue
    let body = first + 2
    if body >= past or tokens[body].line <= tokens[first].line or
        tokens[body].column <= tokens[first].column:
      scopeIndex.uncertainty.incl scopeNestedBlock
      continue

    var parent = routineScope
    for ordinal, candidate in scopeIndex.scopes:
      if candidate.kind != scopeBlock or candidate.firstToken >= node.firstToken or
          candidate.pastToken < node.pastToken:
        continue
      let parentOrdinal = int(uint32(parent)) - 1
      if parentOrdinal < 0 or
          candidate.firstToken >= scopeIndex.scopes[parentOrdinal].firstToken:
        parent = ScopeId(uint32(ordinal + 1))

    scopeIndex.scopes.add ScopeInterval(
      parent: parent,
      kind: scopeBlock,
      ownerSymbol: invalidScopeOwner,
      firstToken: node.firstToken,
      pastToken: node.pastToken,
      startOffset: tokens[first].startOffset,
      endOffset: routineBodyEnd(tokens, past, byteLength),
    )
  true

proc locals[T](
    tokens: T,
    bounds: tuple[first, past, baseColumn: int, valid: bool],
    scope: ScopeId,
    declarations: var seq[LexicalDeclaration],
    result: var ScopeIndex,
) =
  if not bounds.valid:
    return
  var index = bounds.first
  while index < bounds.past:
    let token = tokens[index]
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

proc routineBodyEnd[T](tokens: T, past, byteLength: int): int =
  if past >= tokens.len:
    return byteLength
  tokens[past].startOffset

proc indexedRoutine[T](
    tokens: T,
    symbol: SourceSymbol,
    symbolIndex: int,
    byteLength: int,
    syntax: PartialSyntaxTree,
    result: var ScopeIndex,
) =
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
    if tokens[index].text == "[":
      result.uncertainty.incl scopeUnsupportedHeader
      return
  for index in header.closing + 1 ..< header.equals:
    if tokens[index].text == "{" or tokens[index].text == "[":
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

proc indexScopes*[T](
    tokens: T,
    symbols: openArray[SourceSymbol],
    byteLength: int,
    syntax: PartialSyntaxTree,
): ScopeIndex =
  result.scopes.add ScopeInterval(
    parent: InvalidScopeId,
    kind: scopeModule,
    ownerSymbol: invalidScopeOwner,
    firstToken: 0,
    pastToken: uint32(tokens.len),
    startOffset: 0,
    endOffset: byteLength,
  )
  markMalformed(tokens, result)
  markGlobalUncertainty(tokens, result)

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

proc indexScopes*[T](
    tokens: T, symbols: openArray[SourceSymbol], byteLength: int
): ScopeIndex =
  var copied = newSeqOfCap[Token](tokens.len)
  for token in tokens:
    copied.add token
  let syntax = parsePartialSyntax(initTokenStore(copied))
  indexScopes(tokens, symbols, byteLength, syntax)

proc containsToken(scope: ScopeInterval, token: uint32): bool {.inline.} =
  token >= scope.firstToken and token < scope.pastToken

proc scopeContains(index: ScopeIndex, scope: ScopeId, token: uint32): bool =
  let ordinal = int(uint32(scope)) - 1
  ordinal >= 0 and ordinal < index.scopes.len and
    index.scopes[ordinal].containsToken(token)

proc validateScopes*[T](
    index: ScopeIndex, tokens: T, symbols: openArray[SourceSymbol], byteLength: int
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
    if scope.firstToken < uint32(tokens.len) and
        scope.startOffset != tokens[int(scope.firstToken)].startOffset:
      return false
    if scope.pastToken < uint32(tokens.len) and
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
          index.scopes[parentOrdinal].kind notin {scopeRoutine, scopeBlock} or
          scope.firstToken + 1 >= uint32(tokens.len) or
          tokens[int(scope.firstToken)].text != "block" or
          tokens[int(scope.firstToken) + 1].text != ":":
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

proc isComplete*(index: ScopeIndex): bool =
  index.uncertainty == {}

proc innermostScopeAt*(index: ScopeIndex, token: uint32): ScopeId =
  for ordinal, scope in index.scopes:
    if scope.containsToken(token):
      if result == InvalidScopeId:
        result = ScopeId(uint32(ordinal + 1))
      elif scope.firstToken >= index.scopes[int(uint32(result)) - 1].firstToken:
        result = ScopeId(uint32(ordinal + 1))
