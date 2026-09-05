import std/strutils

type
  TokenKind* = enum
    tkIdentifier
    tkString
    tkPunctuation

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
    text*: string
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

const tokenBlockLength* = 64

type
  TokenBase = ref object
    values: seq[Token]

  TokenBlock = ref object
    values: array[tokenBlockLength, Token]

  TokenOverrides = ref object
    blocks: seq[TokenBlock]

  TokenStore* = object
    base: TokenBase
    overrides: TokenOverrides
    count: int

proc initTokenStore*(tokens: sink seq[Token]): TokenStore =
  new(result.base)
  result.base.values = tokens
  result.count = tokens.len

proc len*(tokens: TokenStore): int {.inline.} =
  tokens.count

proc high*(tokens: TokenStore): int {.inline.} =
  tokens.count - 1

proc `[]`*(tokens: TokenStore, index: int): lent Token {.inline.} =
  if index < 0 or index >= tokens.count:
    raise newException(IndexDefect, "token index out of bounds")
  let blockIndex = index div tokenBlockLength
  if tokens.overrides != nil and tokens.overrides.blocks[blockIndex] != nil:
    return tokens.overrides.blocks[blockIndex].values[index mod tokenBlockLength]
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
  while index < tokens.count:
    yield tokens[index]
    inc index

iterator pairs*(tokens: TokenStore): (int, lent Token) =
  var index = 0
  while index < tokens.count:
    yield (index, tokens[index])
    inc index

proc copyDirectory(tokens: TokenStore): TokenOverrides =
  new(result)
  let blockCount = (tokens.count + tokenBlockLength - 1) div tokenBlockLength
  result.blocks = newSeq[TokenBlock](blockCount)
  if tokens.overrides != nil:
    for index in 0 ..< blockCount:
      result.blocks[index] = tokens.overrides.blocks[index]

proc copyBlock(tokens: TokenStore, blockIndex: int): TokenBlock =
  new(result)
  let first = blockIndex * tokenBlockLength
  let past = min(tokens.count, first + tokenBlockLength)
  for index in first ..< past:
    result.values[index - first] = tokens[index]

proc withToken*(tokens: TokenStore, index: int, token: sink Token): TokenStore =
  if index < 0 or index >= tokens.count:
    raise newException(IndexDefect, "token index out of bounds")
  result = tokens
  result.overrides = copyDirectory(tokens)
  let blockIndex = index div tokenBlockLength
  result.overrides.blocks[blockIndex] = copyBlock(tokens, blockIndex)
  result.overrides.blocks[blockIndex].values[index mod tokenBlockLength] = token

proc toSeq*(tokens: TokenStore): seq[Token] =
  result = newSeqOfCap[Token](tokens.count)
  for token in tokens:
    result.add token

proc `==`*(left, right: TokenStore): bool =
  if left.count != right.count:
    return false
  for index in 0 ..< left.count:
    if left[index] != right[index]:
      return false
  true

proc `==`*(left: TokenStore, right: openArray[Token]): bool =
  if left.count != right.len:
    return false
  for index in 0 ..< left.count:
    if left[index] != right[index]:
      return false
  true

proc `==`*(left: openArray[Token], right: TokenStore): bool =
  right == left

proc keywordId*(text: string): NimKeyword {.inline.} =
  case text
  of "addr": kwAddr
  of "and": kwAnd
  of "as": kwAs
  of "asm": kwAsm
  of "atomic": kwAtomic
  of "bind": kwBind
  of "block": kwBlock
  of "break": kwBreak
  of "case": kwCase
  of "cast": kwCast
  of "concept": kwConcept
  of "const": kwConst
  of "continue": kwContinue
  of "converter": kwConverter
  of "defer": kwDefer
  of "discard": kwDiscard
  of "distinct": kwDistinct
  of "div": kwDiv
  of "do": kwDo
  of "elif": kwElif
  of "else": kwElse
  of "end": kwEnd
  of "enum": kwEnum
  of "except": kwExcept
  of "export": kwExport
  of "finally": kwFinally
  of "for": kwFor
  of "from": kwFrom
  of "func": kwFunc
  of "generic": kwGeneric
  of "if": kwIf
  of "import": kwImport
  of "in": kwIn
  of "include": kwInclude
  of "interface": kwInterface
  of "is": kwIs
  of "isnot": kwIsnot
  of "iterator": kwIterator
  of "let": kwLet
  of "macro": kwMacro
  of "method": kwMethod
  of "mixin": kwMixin
  of "mod": kwMod
  of "nil": kwNil
  of "not": kwNot
  of "object": kwObject
  of "of": kwOf
  of "or": kwOr
  of "out": kwOut
  of "proc": kwProc
  of "ptr": kwPtr
  of "raise": kwRaise
  of "ref": kwRef
  of "return": kwReturn
  of "shl": kwShl
  of "shr": kwShr
  of "static": kwStatic
  of "template": kwTemplate
  of "try": kwTry
  of "tuple": kwTuple
  of "type": kwType
  of "using": kwUsing
  of "var": kwVar
  of "when": kwWhen
  of "while": kwWhile
  of "with": kwWith
  of "without": kwWithout
  of "xor": kwXor
  of "yield": kwYield
  else: kwNone

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
  token.kind == tkIdentifier and token.text.len > 0 and
    tokenSpan(token) >= token.text.len + 1

proc keywordOf*(token: Token): NimKeyword {.inline.} =
  if token.keyword != kwNone:
    return token.keyword
  if token.kind == tkIdentifier and not isStropped(token):
    return keywordId(token.text)
  kwNone

proc isKeyword*(token: Token, wanted: NimKeyword): bool {.inline.} =
  token.kind == tkIdentifier and not isStropped(token) and keywordOf(token) == wanted

proc hasKeywordRole*(token: Token, role: KeywordRole): bool {.inline.} =
  let keyword = keywordOf(token)
  keyword != kwNone and role in keywordRoles(keyword)

proc isExportMarker*[T](tokens: T, index: int): bool {.inline.} =
  if index <= 0 or index >= tokens.len or tokens[index].text != "*" or
      tokens[index - 1].kind != tkIdentifier or
      tokens[index - 1].line != tokens[index].line:
    return false
  var cursor = index - 2
  while cursor >= 0:
    if tokens[cursor].line == tokens[index].line:
      if tokens[cursor].text == "=" or tokens[cursor].text == ";":
        return false
      if tokens[cursor].hasKeywordRole(roleDeclaration):
        return true
    elif tokens[cursor].column == 0:
      return
        tokens[cursor].hasKeywordRole(roleTypeDeclaration) or
        tokens[cursor].hasKeywordRole(roleValueDeclaration)
    dec cursor
  false

proc isRoutineHeaderEquals*[T](tokens: T, index: int): bool {.inline.} =
  if index <= 0 or index >= tokens.len or tokens[index].text != "=":
    return false
  var cursor = index - 1
  while cursor >= 0 and tokens[cursor].line == tokens[index].line:
    if tokens[cursor].text == "=" or tokens[cursor].text == ";":
      return false
    if tokens[cursor].hasKeywordRole(roleRoutine):
      return not tokens[cursor].hasKeywordRole(roleGenerated)
    dec cursor
  false

proc validIdentifier*(token: Token): bool {.inline.} =
  if token.kind != tkIdentifier or token.text.len == 0:
    return false
  let span = tokenSpan(token)
  span == token.text.len or span == token.text.len + 2

proc isClosedString*(token: Token): bool {.inline.} =
  if token.kind != tkString or token.text.len < 2:
    return false
  let triple =
    token.text.len >= 3 and token.text[0] == '"' and token.text[1] == '"' and
    token.text[2] == '"'
  if triple:
    return
      token.text.len >= 6 and token.text[^3] == '"' and token.text[^2] == '"' and
      token.text[^1] == '"'
  (token.text[0] == '"' or token.text[0] == char(39)) and token.text[^1] == token.text[
    0
  ]

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

    if token.kind != tkPunctuation or token.text.len != 1:
      continue
    let value = token.text[0]
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
) =
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
        break
    elif source[position] == quote:
      advance(source, position, line, column)
      break

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

proc lex*(source: string): seq[Token] =
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
      let contentStart = position
      while position < source.len and source[position] != '`':
        advance(source, position, line, column)
      let contentEnd = position
      if position < source.len:
        advance(source, position, line, column)
      result.add Token(
        kind: tkIdentifier,
        text: source[contentStart ..< contentEnd],
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
      skipQuoted(source, position, line, column, c, triple)
      result.add Token(
        kind: tkString,
        text: source[start ..< position],
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
        skipQuoted(source, position, line, column, '"', triple)
      else:
        let start = position
        let tokenLine = line
        let tokenColumn = column
        while position < source.len and isIdentifierContinue(source[position]):
          advance(source, position, line, column)
        result.add Token(
          kind: tkIdentifier,
          keyword: keywordId(source[start ..< position]),
          text: source[start ..< position],
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
      result.add Token(
        kind: tkPunctuation,
        text: source[start ..< position],
        startOffset: start,
        endOffset: position,
        line: tokenLine,
        column: tokenColumn,
      )

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
