import std/strutils

type
  TokenKind* = enum
    tkIdentifier
    tkString
    tkPunctuation

  Token* = object
    kind*: TokenKind
    text*: string
    startOffset*: int
    endOffset*: int
    line*: int
    column*: int

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
