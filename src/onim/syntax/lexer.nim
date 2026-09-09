import std/strutils

import ./tokens

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

proc advanceNumber(source: string, position: var int, line: var int, column: var int) =
  let first = position
  while position < source.len and (source[position].isDigit or source[position] == '_'):
    advance(source, position, line, column)

  let based =
    position < source.len and source[first] == '0' and
    source[position] in {'b', 'B', 'o', 'O', 'x', 'X'}
  if based:
    advance(source, position, line, column)
    while position < source.len and (
      source[position].isAlphaAscii or source[position].isDigit or
      source[position] == '_'
    )
    :
      advance(source, position, line, column)
  else:
    if position + 1 < source.len and source[position] == '.' and
        source[position + 1] != '.':
      advance(source, position, line, column)
      while position < source.len and
          (source[position].isDigit or source[position] == '_'):
        advance(source, position, line, column)

    if position < source.len and source[position] in {'e', 'E'}:
      advance(source, position, line, column)
      if position < source.len and source[position] in {'+', '-'}:
        advance(source, position, line, column)
      while position < source.len and
          (source[position].isDigit or source[position] == '_'):
        advance(source, position, line, column)

  let quoted = position < source.len and source[position] == '\''
  var suffixFirst = position
  if quoted:
    inc suffixFirst
  var suffixPast = suffixFirst
  while suffixPast < source.len and isIdentifierContinue(source[suffixPast]):
    inc suffixPast
  if suffixPast > suffixFirst and numericSuffixSupported(
    source, suffixFirst, suffixPast
  ):
    while position < suffixPast:
      advance(source, position, line, column)

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
    elif c.isDigit:
      let start = position
      let tokenLine = line
      let tokenColumn = column
      advanceNumber(source, position, line, column)
      values.add Token(
        kind: tkNumber,
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
