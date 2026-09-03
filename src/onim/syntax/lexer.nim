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

proc validIdentifier*(token: Token): bool {.inline.} =
  if token.kind != tkIdentifier or token.text.len == 0:
    return false
  let span = tokenSpan(token)
  span == token.text.len or span == token.text.len + 2

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
