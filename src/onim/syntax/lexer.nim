import std/strutils

type
  TokenKind* = enum
    tkIdentifier
    tkString
    tkPunctuation

  TokenFlag* = enum
    tfStropped
    tfClosed

  NimKeyword* = enum
    kwNone
    kwAddr
    kwAnd
    kwAs
    kwAsm
    kwAtomic
    kwBind
    kwBlock
    kwBreak
    kwCase
    kwCast
    kwConcept
    kwConst
    kwContinue
    kwConverter
    kwDefer
    kwDiscard
    kwDistinct
    kwDiv
    kwDo
    kwElif
    kwElse
    kwEnd
    kwEnum
    kwExcept
    kwExport
    kwFinally
    kwFor
    kwFrom
    kwFunc
    kwGeneric
    kwIf
    kwImport
    kwIn
    kwInclude
    kwInterface
    kwIs
    kwIsnot
    kwIterator
    kwLet
    kwMacro
    kwMethod
    kwMixin
    kwMod
    kwNil
    kwNot
    kwObject
    kwOf
    kwOr
    kwOut
    kwProc
    kwPtr
    kwRaise
    kwRef
    kwReturn
    kwShl
    kwShr
    kwStatic
    kwTemplate
    kwTry
    kwTuple
    kwType
    kwUsing
    kwVar
    kwWhen
    kwWhile
    kwWith
    kwWithout
    kwXor
    kwYield

  KeywordRole* = enum
    roleRoutine
    roleDeclaration
    roleTypeDeclaration
    roleValueDeclaration
    roleForBinding
    roleBindDeclaration
    roleBlock
    roleConditional
    roleInclude
    roleGenerated
    roleImport
    roleFrom
    roleAlias
    roleExcept
    roleExport

  Token* = object
    kind*: TokenKind
    keyword*: NimKeyword
    flags*: set[TokenFlag]
    startOffset*: int
    endOffset*: int
    line*: int
    column*: int

  LexicalIssueKind* = enum
    lexicalMalformedIdentifier
    lexicalUnclosedString
    lexicalUnexpectedDelimiter
    lexicalUnclosedDelimiter

  LexicalIssue* = object
    kind*: LexicalIssueKind
    tokenIndex*: uint32

type
  TokenBase = ref object
    values: seq[Token]
    source: string

  TokenStore* = object
    base: TokenBase

const keywordSpellings: array[NimKeyword, string] = [
  "", "addr", "and", "as", "asm", "atomic", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard", "distinct", "div",
  "do", "elif", "else", "end", "enum", "except", "export", "finally", "for", "from",
  "func", "generic", "if", "import", "in", "include", "interface", "is", "isnot",
  "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not", "object", "of",
  "or", "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
  "template", "try", "tuple", "type", "using", "var", "when", "while", "with",
  "without", "xor", "yield",
]

proc spanEquals(source: string, start, past: int, wanted: string): bool {.inline.} =
  if start < 0 or past < start or past > source.len or past - start != wanted.len:
    return false
  for index in 0 ..< wanted.len:
    if source[start + index] != wanted[index]:
      return false
  true

proc identifierCharacter(character: char, position: int): char {.inline.} =
  if position > 0 and character >= 'A' and character <= 'Z':
    char(ord(character) + (ord('a') - ord('A')))
  else:
    character

proc appendIdentifierKey(result: var string, source: string, first, past: int) =
  var position = 0
  for index in first ..< past:
    let character = source[index]
    if character == '_' and position > 0:
      continue
    result.add identifierCharacter(character, position)
    inc position

proc identifierKey*(value: string): string =
  ## Nim's style-insensitive identifier key for the ASCII spelling common to
  ## source declarations. The first character retains its case; later ASCII
  ## letters are folded and underscores are ignored.
  if value.len == 0:
    return
  result = newStringOfCap(value.len)
  result.appendIdentifierKey(value, 0, value.len)

proc sameIdentifier*(left, right: string): bool =
  identifierKey(left) == identifierKey(right)

proc initTokenStore*(source: string, tokens: sink seq[Token]): TokenStore =
  new(result.base)
  result.base.values = tokens
  result.base.source = source

proc rebindSource*(tokens: TokenStore, source: string): TokenStore =
  new(result.base)
  result.base.values =
    if tokens.base == nil:
      @[]
    else:
      tokens.base.values
  result.base.source = source

proc sourceText*(tokens: TokenStore): string {.inline.} =
  if tokens.base != nil:
    result = tokens.base.source

proc tokenTextBounds(
    tokens: TokenStore, token: Token
): tuple[first, past: int] {.inline.} =
  if tokens.base == nil:
    return
  result.first = token.startOffset
  result.past = token.endOffset
  if tfStropped in token.flags:
    inc result.first
    if tfClosed in token.flags:
      dec result.past
  if result.first < 0 or result.past < result.first or
      result.past > tokens.base.source.len:
    result = (0, 0)

proc tokenTextLen*(tokens: TokenStore, token: Token): int {.inline.} =
  let bounds = tokens.tokenTextBounds(token)
  bounds.past - bounds.first

proc tokenTextChar*(tokens: TokenStore, token: Token, index: int): char {.inline.} =
  let bounds = tokens.tokenTextBounds(token)
  if index < 0 or bounds.first + index >= bounds.past:
    raise newException(IndexDefect, "token text index out of bounds")
  tokens.base.source[bounds.first + index]

proc tokenTextEquals*(
    tokens: TokenStore, token: Token, wanted: string
): bool {.inline.} =
  if tokens.base == nil:
    return false
  let bounds = tokens.tokenTextBounds(token)
  spanEquals(tokens.base.source, bounds.first, bounds.past, wanted)

proc tokenText*(tokens: TokenStore, token: Token): string =
  let bounds = tokens.tokenTextBounds(token)
  if bounds.first < bounds.past:
    result = tokens.base.source[bounds.first ..< bounds.past]

proc identifierKey*(tokens: TokenStore, token: Token): string =
  let bounds = tokens.tokenTextBounds(token)
  if bounds.first >= bounds.past:
    return
  result = newStringOfCap(bounds.past - bounds.first)
  result.appendIdentifierKey(tokens.base.source, bounds.first, bounds.past)

proc identifierContainsKey*(tokens: TokenStore, token: Token, wanted: string): bool =
  if wanted.len == 0:
    return true
  let bounds = tokens.tokenTextBounds(token)
  var start = bounds.first
  while start < bounds.past:
    var position = if start == bounds.first: 0 else: 1
    var queryIndex = 0
    var cursor = start
    while cursor < bounds.past and queryIndex < wanted.len:
      let character = tokens.base.source[cursor]
      if character == '_' and position > 0:
        inc cursor
        continue
      if identifierCharacter(character, position) != wanted[queryIndex]:
        break
      inc cursor
      inc position
      inc queryIndex
    if queryIndex == wanted.len:
      return true
    inc start

proc len*(tokens: TokenStore): int {.inline.} =
  if tokens.base == nil: 0 else: tokens.base.values.len

proc high*(tokens: TokenStore): int {.inline.} =
  tokens.len - 1

proc `[]`*(tokens: TokenStore, index: int): lent Token {.inline.} =
  if index < 0 or index >= tokens.len:
    raise newException(IndexDefect, "token index out of bounds")
  tokens.base.values[index]

proc tokenContaining*(tokens: TokenStore, startOffset, endOffset: int): int =
  var first = 0
  var past = tokens.len
  while first < past:
    let middle = (first + past) div 2
    if tokens[middle].startOffset <= startOffset:
      first = middle + 1
    else:
      past = middle
  let candidate = first - 1
  if candidate >= 0 and tokens[candidate].startOffset <= startOffset and
      endOffset <= tokens[candidate].endOffset: candidate else: -1

proc tokenAtOffset*(tokens: TokenStore, offset: int): int =
  if offset < 0:
    return -1
  let candidate = tokens.tokenContaining(offset, offset + 1)
  if candidate >= 0 and tokens[candidate].kind == tkIdentifier: candidate else: -1

iterator items*(tokens: TokenStore): lent Token =
  var index = 0
  while index < tokens.len:
    yield tokens[index]
    inc index

iterator pairs*(tokens: TokenStore): (int, lent Token) =
  var index = 0
  while index < tokens.len:
    yield (index, tokens[index])
    inc index

proc `==`*(left, right: TokenStore): bool =
  if left.len != right.len or left.sourceText != right.sourceText:
    return false
  for index in 0 ..< left.len:
    if left[index] != right[index]:
      return false
  true

proc keywordId*(text: string): NimKeyword {.inline.} =
  for keyword in NimKeyword:
    if keyword != kwNone and text == keywordSpellings[keyword]:
      return keyword
  kwNone

proc keywordIdAt*(source: string, start, past: int): NimKeyword {.inline.} =
  for keyword in NimKeyword:
    if keyword != kwNone and spanEquals(source, start, past, keywordSpellings[keyword]):
      return keyword
  kwNone

proc keywordRoles*(keyword: NimKeyword): set[KeywordRole] {.inline.} =
  case keyword
  of kwProc, kwFunc, kwIterator, kwMethod, kwConverter:
    {roleRoutine, roleDeclaration}
  of kwMacro, kwTemplate:
    {roleRoutine, roleDeclaration, roleGenerated}
  of kwType:
    {roleDeclaration, roleTypeDeclaration}
  of kwVar, kwLet, kwConst:
    {roleDeclaration, roleValueDeclaration}
  of kwFor:
    {roleDeclaration, roleForBinding, roleBlock}
  of kwBind:
    {roleDeclaration, roleBindDeclaration}
  of kwWhen, kwElif, kwElse:
    {roleBlock, roleConditional}
  of kwIf, kwCase, kwWhile, kwBlock, kwTry, kwFinally, kwOf, kwDefer:
    {roleBlock}
  of kwExcept:
    {roleBlock, roleExcept}
  of kwStatic:
    {roleConditional}
  of kwInclude:
    {roleInclude}
  of kwMixin:
    {roleGenerated}
  of kwImport:
    {roleImport}
  of kwFrom:
    {roleFrom}
  of kwAs:
    {roleAlias}
  of kwExport:
    {roleExport}
  else:
    {}

proc isNimKeyword*(text: string): bool {.inline.} =
  keywordId(text) != kwNone

proc tokenSpan(token: Token): int {.inline.} =
  token.endOffset - token.startOffset

proc isStropped*(token: Token): bool {.inline.} =
  token.kind == tkIdentifier and tfStropped in token.flags

proc keywordOf*(token: Token): NimKeyword {.inline.} =
  token.keyword

proc isKeyword*(token: Token, wanted: NimKeyword): bool {.inline.} =
  token.kind == tkIdentifier and not isStropped(token) and keywordOf(token) == wanted

proc hasKeywordRole*(token: Token, role: KeywordRole): bool {.inline.} =
  let keyword = keywordOf(token)
  keyword != kwNone and role in keywordRoles(keyword)

proc isExportMarker*(tokens: TokenStore, index: int): bool {.inline.} =
  if index <= 0 or index >= tokens.len or not tokens.tokenTextEquals(tokens[index], "*") or
      tokens[index - 1].kind != tkIdentifier or
      tokens[index - 1].line != tokens[index].line:
    return false
  var cursor = index - 2
  while cursor >= 0:
    if tokens[cursor].line == tokens[index].line:
      if tokens.tokenTextEquals(tokens[cursor], "=") or
          tokens.tokenTextEquals(tokens[cursor], ";"):
        return false
      if tokens[cursor].hasKeywordRole(roleDeclaration):
        return true
    elif tokens[cursor].column == 0:
      return
        tokens[cursor].hasKeywordRole(roleTypeDeclaration) or
        tokens[cursor].hasKeywordRole(roleValueDeclaration)
    dec cursor
  false

proc isRoutineHeaderEquals*(tokens: TokenStore, index: int): bool {.inline.} =
  if index <= 0 or index >= tokens.len or not tokens.tokenTextEquals(tokens[index], "="):
    return false
  var cursor = index - 1
  while cursor >= 0 and tokens[cursor].line == tokens[index].line:
    if tokens.tokenTextEquals(tokens[cursor], "=") or
        tokens.tokenTextEquals(tokens[cursor], ";"):
      return false
    if tokens[cursor].hasKeywordRole(roleRoutine):
      return not tokens[cursor].hasKeywordRole(roleGenerated)
    dec cursor
  false

proc validIdentifier*(token: Token): bool {.inline.} =
  if token.kind != tkIdentifier or token.endOffset <= token.startOffset:
    return false
  if isStropped(token):
    return tfClosed in token.flags and tokenSpan(token) > 2
  true

proc isClosedString*(token: Token): bool {.inline.} =
  token.kind == tkString and tfClosed in token.flags

proc matchingDelimiter*(opening, closing: char): bool {.inline.} =
  case closing
  of ')':
    opening == '('
  of ']':
    opening == '['
  of '}':
    opening == '{'
  else:
    false

proc isOpeningDelimiter*(value: char): bool {.inline.} =
  value in {'(', '[', '{'}

proc isClosingDelimiter*(value: char): bool {.inline.} =
  value in {')', ']', '}'}

type LexicalDelimiter = object
  value: char
  tokenIndex: uint32

proc lexicalIssues*(tokens: TokenStore): seq[LexicalIssue] =
  var delimiters: seq[LexicalDelimiter] = @[]
  for tokenIndex, token in tokens:
    if token.kind == tkIdentifier and not validIdentifier(token):
      result.add LexicalIssue(
        kind: lexicalMalformedIdentifier, tokenIndex: uint32(tokenIndex)
      )
    elif token.kind == tkString and not isClosedString(token):
      result.add LexicalIssue(
        kind: lexicalUnclosedString, tokenIndex: uint32(tokenIndex)
      )

    if token.kind != tkPunctuation or tokens.tokenTextLen(token) != 1:
      continue
    let value = tokens.tokenTextChar(token, 0)
    if isOpeningDelimiter(value):
      delimiters.add LexicalDelimiter(value: value, tokenIndex: uint32(tokenIndex))
    elif isClosingDelimiter(value):
      if delimiters.len == 0 or not matchingDelimiter(delimiters[^1].value, value):
        result.add LexicalIssue(
          kind: lexicalUnexpectedDelimiter, tokenIndex: uint32(tokenIndex)
        )
      else:
        delimiters.setLen(delimiters.len - 1)

  for delimiter in delimiters:
    result.add LexicalIssue(
      kind: lexicalUnclosedDelimiter, tokenIndex: delimiter.tokenIndex
    )

proc isNimKeyword*(token: Token): bool {.inline.} =
  keywordOf(token) != kwNone

proc isValidNimKeyword*(token: Token): bool {.inline.} =
  validIdentifier(token) and isNimKeyword(token)

proc isIdentifierStart(c: char): bool {.inline.} =
  c == '_' or c.isAlphaAscii or ord(c) >= 128

proc isIdentifierContinue(c: char): bool {.inline.} =
  isIdentifierStart(c) or c.isDigit

proc advance(
    source: string, position: var int, line: var int, column: var int
) {.inline.} =
  if source[position] == '\n':
    inc line
    column = 0
  else:
    inc column
  inc position

proc skipQuoted(
    source: string,
    position: var int,
    line: var int,
    column: var int,
    quote: char,
    triple: bool,
): bool =
  if triple:
    for _ in 0 ..< 3:
      if position < source.len:
        advance(source, position, line, column)
  elif position < source.len:
    advance(source, position, line, column)

  while position < source.len:
    if not triple and source[position] == '\\':
      advance(source, position, line, column)
      if position < source.len:
        advance(source, position, line, column)
      continue

    if triple:
      if position + 2 < source.len and source[position] == quote and
          source[position + 1] == quote and source[position + 2] == quote:
        for _ in 0 ..< 3:
          advance(source, position, line, column)
        return true
    elif source[position] == quote:
      advance(source, position, line, column)
      return true

    advance(source, position, line, column)

proc skipComment(source: string, position: var int, line: var int, column: var int) =
  if position + 1 < source.len and source[position + 1] == '[':
    advance(source, position, line, column)
    advance(source, position, line, column)
    var depth = 1
    while position < source.len and depth > 0:
      if position + 1 < source.len and source[position] == '#' and
          source[position + 1] == '[':
        advance(source, position, line, column)
        advance(source, position, line, column)
        inc depth
      elif position + 1 < source.len and source[position] == ']' and
          source[position + 1] == '#':
        advance(source, position, line, column)
        advance(source, position, line, column)
        dec depth
      else:
        advance(source, position, line, column)
  else:
    while position < source.len and source[position] != '\n':
      advance(source, position, line, column)

proc lex*(source: string): TokenStore =
  var values: seq[Token] = @[]
  var position = 0
  var line = 0
  var column = 0

  if source.len >= 3 and ord(source[0]) == 0xEF and ord(source[1]) == 0xBB and
      ord(source[2]) == 0xBF:
    position = 3

  while position < source.len:
    let c = source[position]
    if c in {' ', '\t', '\r', '\n'}:
      advance(source, position, line, column)
    elif c == '#':
      skipComment(source, position, line, column)
    elif c == '`':
      let start = position
      let tokenLine = line
      let tokenColumn = column
      advance(source, position, line, column)
      while position < source.len and source[position] != '`':
        advance(source, position, line, column)
      let closed = position < source.len
      if closed:
        advance(source, position, line, column)
      var flags: set[TokenFlag] = {tfStropped}
      if closed:
        flags.incl tfClosed
      values.add Token(
        kind: tkIdentifier,
        flags: flags,
        startOffset: start,
        endOffset: position,
        line: tokenLine,
        column: tokenColumn,
      )
    elif c in {'"', '\''}:
      let start = position
      let tokenLine = line
      let tokenColumn = column
      let triple =
        c == '"' and position + 2 < source.len and source[position + 1] == '"' and
        source[position + 2] == '"'
      let closed = skipQuoted(source, position, line, column, c, triple)
      var flags: set[TokenFlag] = {}
      if closed:
        flags.incl tfClosed
      values.add Token(
        kind: tkString,
        flags: flags,
        startOffset: start,
        endOffset: position,
        line: tokenLine,
        column: tokenColumn,
      )
    elif isIdentifierStart(c):
      # Nim string prefixes (r"...", t"...", &"...") are not identifiers.
      let isStringPrefix =
        position + 1 < source.len and c in {'r', 'R', 't', 'T', 'b', 'B', 'f', 'F', '&'} and
        source[position + 1] == '"'
      if isStringPrefix:
        advance(source, position, line, column)
        let triple =
          position + 2 < source.len and source[position + 1] == '"' and
          source[position + 2] == '"'
        discard skipQuoted(source, position, line, column, '"', triple)
      else:
        let start = position
        let tokenLine = line
        let tokenColumn = column
        while position < source.len and isIdentifierContinue(source[position]):
          advance(source, position, line, column)
        values.add Token(
          kind: tkIdentifier,
          keyword: keywordIdAt(source, start, position),
          startOffset: start,
          endOffset: position,
          line: tokenLine,
          column: tokenColumn,
        )
    else:
      let start = position
      let tokenLine = line
      let tokenColumn = column
      advance(source, position, line, column)
      values.add Token(
        kind: tkPunctuation,
        startOffset: start,
        endOffset: position,
        line: tokenLine,
        column: tokenColumn,
      )

  initTokenStore(source, values)

proc lineEndOffset*(source: string, offset: int): int =
  var position = max(0, min(offset, source.len))
  while position < source.len and source[position] != '\n':
    inc position
  if position < source.len:
    inc position
  position

proc lineStartOffset*(source: string, line: int): int =
  if line <= 0:
    return 0
  var currentLine = 0
  for position, c in source:
    if c == '\n':
      inc currentLine
      if currentLine == line:
        return position + 1
  source.len
