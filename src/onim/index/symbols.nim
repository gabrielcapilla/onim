import ../syntax/tokens

type
  SourceSymbolKind* = enum
    symbolProc
    symbolFunc
    symbolIterator
    symbolMethod
    symbolMacro
    symbolTemplate
    symbolConverter
    symbolType
    symbolVar
    symbolLet
    symbolConst

  SourceSymbol* = object
    ## A declaration whose name is stored in the source token stream.
    nameToken*: uint32
    kind*: SourceSymbolKind
    exported*: bool

proc normalToken(token: Token): bool =
  token.kind == tkIdentifier and validIdentifier(token) and not isStropped(token)

proc keyword(token: Token, wanted: NimKeyword): bool =
  normalToken(token) and token.isKeyword(wanted)

proc sectionEnd(tokens: TokenStore, start: int): int =
  let startLine = tokens[start].line
  result = tokens.len
  for index in start + 1 ..< tokens.len:
    if tokens[index].line > startLine and tokens[index].column == 0:
      return index

proc addSymbol(
    symbols: var seq[SourceSymbol],
    tokens: TokenStore,
    tokenIndex: int,
    kind: SourceSymbolKind,
): bool =
  if tokenIndex < 0 or tokenIndex >= tokens.len or
      tokens[tokenIndex].kind != tkIdentifier:
    return false
  let exported = tokenIndex + 1 < tokens.len and tokens.isExportMarker(tokenIndex + 1)
  symbols.add SourceSymbol(
    nameToken: uint32(tokenIndex), kind: kind, exported: exported
  )
  true

proc declarationNameEnd(
    tokens: TokenStore, start, limit: int, typeDeclaration: bool
): bool =
  ## Check the short, same-line prefix of a declaration without trying to
  ## parse its type or body. This intentionally returns false for uncertain
  ## constructs so a later parser can replace this conservative scan.
  if start < 0 or start >= limit or tokens[start].kind != tkIdentifier:
    return false
  var cursor = start + 1
  if cursor < limit and tokens.tokenTextEquals(tokens[cursor], "*"):
    inc cursor
  if typeDeclaration:
    if cursor < limit and tokens.tokenTextEquals(tokens[cursor], "["):
      var depth = 0
      while cursor < limit:
        if tokens[cursor].line != tokens[start].line:
          return false
        if tokens.tokenTextEquals(tokens[cursor], "["):
          inc depth
        elif tokens.tokenTextEquals(tokens[cursor], "]"):
          dec depth
          if depth == 0:
            inc cursor
            break
        inc cursor
    while cursor < limit and tokens[cursor].line == tokens[start].line and
        not tokens.tokenTextEquals(tokens[cursor], "=") and
        not tokens.tokenTextEquals(tokens[cursor], ";")
    :
      inc cursor
  cursor < limit and tokens.tokenTextEquals(tokens[cursor], "=") and
    tokens[cursor].line == tokens[start].line

proc collectTypeSymbols(
    tokens: TokenStore, start: int, symbols: var seq[SourceSymbol]
) =
  let limit = sectionEnd(tokens, start)
  var cursor = start + 1
  while cursor < limit and tokens[cursor].line == tokens[start].line:
    if tokens[cursor].kind == tkIdentifier and
        declarationNameEnd(tokens, cursor, limit, typeDeclaration = true):
      discard addSymbol(symbols, tokens, cursor, symbolType)
      break
    inc cursor

  var bodyIndent = -1
  cursor = start + 1
  while cursor < limit:
    if tokens[cursor].line == tokens[start].line:
      inc cursor
      continue
    if tokens[cursor].kind == tkIdentifier and
        declarationNameEnd(tokens, cursor, limit, typeDeclaration = true):
      if bodyIndent < 0:
        bodyIndent = tokens[cursor].column
      if tokens[cursor].column == bodyIndent:
        discard addSymbol(symbols, tokens, cursor, symbolType)
    inc cursor

proc lineEnd(tokens: TokenStore, start, limit: int): int =
  result = start
  let line = tokens[start].line
  while result < limit and tokens[result].line == line:
    inc result

proc collectValueLine(
    tokens: TokenStore,
    start, limit: int,
    indent: int,
    kind: SourceSymbolKind,
    symbols: var seq[SourceSymbol],
) =
  if start >= limit or tokens[start].column != indent:
    return
  let finish = lineEnd(tokens, start, limit)
  var cursor = start
  var atName = true
  while cursor < finish:
    let token = tokens[cursor]
    if tokens.tokenTextEquals(token, ";"):
      atName = true
    elif tokens.tokenTextEquals(token, ":") or tokens.tokenTextEquals(token, "="):
      break
    elif tokens.tokenTextEquals(token, "*"):
      discard
    elif tokens.tokenTextEquals(token, ","):
      atName = true
    elif atName and token.kind == tkIdentifier:
      discard addSymbol(symbols, tokens, cursor, kind)
      atName = false
    else:
      break
    inc cursor

proc collectValueSymbols(
    tokens: TokenStore,
    start: int,
    kind: SourceSymbolKind,
    symbols: var seq[SourceSymbol],
) =
  let limit = sectionEnd(tokens, start)
  var indent = -1
  var cursor = start + 1
  while cursor < limit:
    if tokens[cursor].line == tokens[start].line:
      if indent < 0:
        indent = tokens[cursor].column
      collectValueLine(tokens, cursor, limit, indent, kind, symbols)
      cursor = lineEnd(tokens, cursor, limit)
      continue
    if indent < 0 and tokens[cursor].kind == tkIdentifier:
      indent = tokens[cursor].column
    if tokens[cursor].column == indent:
      collectValueLine(tokens, cursor, limit, indent, kind, symbols)
    cursor = lineEnd(tokens, cursor, limit)

proc collectRoutineSymbol(
    tokens: TokenStore,
    start: int,
    kind: SourceSymbolKind,
    symbols: var seq[SourceSymbol],
) =
  let name = start + 1
  if name < tokens.len and tokens[name].kind == tkIdentifier:
    discard addSymbol(symbols, tokens, name, kind)

proc indexSymbols*(source: string, tokens: TokenStore): seq[SourceSymbol] =
  ## Index only declarations whose keyword is at module indentation. A
  ## complete parser will later provide scopes, overload pairing, and
  ## conditional semantics; this surface intentionally declines to guess.
  var index = 0
  while index < tokens.len:
    if tokens[index].column != 0 or not normalToken(tokens[index]):
      inc index
      continue

    if keyword(tokens[index], kwProc):
      collectRoutineSymbol(tokens, index, symbolProc, result)
    elif keyword(tokens[index], kwFunc):
      collectRoutineSymbol(tokens, index, symbolFunc, result)
    elif keyword(tokens[index], kwIterator):
      collectRoutineSymbol(tokens, index, symbolIterator, result)
    elif keyword(tokens[index], kwMethod):
      collectRoutineSymbol(tokens, index, symbolMethod, result)
    elif keyword(tokens[index], kwMacro):
      collectRoutineSymbol(tokens, index, symbolMacro, result)
    elif keyword(tokens[index], kwTemplate):
      collectRoutineSymbol(tokens, index, symbolTemplate, result)
    elif keyword(tokens[index], kwConverter):
      collectRoutineSymbol(tokens, index, symbolConverter, result)
    elif keyword(tokens[index], kwType):
      collectTypeSymbols(tokens, index, result)
    elif keyword(tokens[index], kwVar):
      collectValueSymbols(tokens, index, symbolVar, result)
    elif keyword(tokens[index], kwLet):
      collectValueSymbols(tokens, index, symbolLet, result)
    elif keyword(tokens[index], kwConst):
      collectValueSymbols(tokens, index, symbolConst, result)
    inc index

proc symbolToken*(symbols: openArray[SourceSymbol], tokenIndex: uint32): int =
  for index, symbol in symbols:
    if symbol.nameToken == tokenIndex:
      return index
  -1

proc lookupSymbol*[T](symbols: openArray[SourceSymbol], tokens: T, name: string): int =
  let wanted = identifierKey(name)
  if wanted.len == 0:
    return -1
  var found = -1
  for index, symbol in symbols:
    if int(symbol.nameToken) >= tokens.len:
      continue
    if identifierKey(tokens, tokens[int(symbol.nameToken)]) == wanted:
      if found >= 0:
        return -1
      found = index
  found
