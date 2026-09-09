import std/strutils

import ./tokens

proc lineIndent*(source: string, offset: int): string =
  var start = offset
  while start > 0 and source[start - 1] != '\n':
    dec start
  while start < offset and source[start] in {' ', '\t'}:
    result.add source[start]
    inc start

proc keepImport*(source: string, tokens: TokenStore, start, finish: int): bool =
  if start < 0 or start >= tokens.len or finish <= start or finish > tokens.len:
    return false
  var lineStart = tokens[start].startOffset
  while lineStart > 0 and source[lineStart - 1] != '\n':
    dec lineStart
  var lineEnd = tokens[start].endOffset
  while lineEnd < source.len and source[lineEnd] != '\n':
    inc lineEnd
  let line = source[lineStart ..< lineEnd].toLowerAscii
  if line.contains("# onim: keep") or line.contains("// onim: keep"):
    return true
  var statement = source[tokens[start].startOffset ..< tokens[finish - 1].endOffset]
  statement = statement.replace(" ", "").replace("\t", "").replace("\r", "")
  statement.contains("{.all.}")

proc conditionalImport*(lines: openArray[string], token: Token): bool =
  if token.line <= 0:
    return false
  var line = token.line - 1
  while line >= 0:
    let text = lines[line].strip
    if text.len == 0 or text.startsWith("#"):
      dec line
      continue
    var indent = 0
    while indent < lines[line].len and lines[line][indent] in {' ', '\t'}:
      inc indent
    if indent < token.column:
      return
        text.startsWith("when ") or text.startsWith("elif ") or text == "else:" or
        text.startsWith("else:")
    if indent <= token.column:
      return false
    dec line
  false

proc conditionalLineStart*(source: string, offset: int): int {.inline.} =
  result = max(0, min(offset, source.len))
  while result > 0 and source[result - 1] notin {'\n', '\r'}:
    dec result

proc conditionalLinePast*(source: string, start: int): int {.inline.} =
  result = max(0, min(start, source.len))
  while result < source.len and source[result] notin {'\n', '\r'}:
    inc result

proc conditionalNextLine*(source: string, past: int): int {.inline.} =
  result = past
  while result < source.len and source[result] in {'\n', '\r'}:
    inc result

proc conditionalPreviousLine*(source: string, start: int): int {.inline.} =
  if start <= 0:
    return -1
  var cursor = start - 1
  while cursor >= 0 and source[cursor] in {'\n', '\r'}:
    dec cursor
  while cursor >= 0 and source[cursor] notin {'\n', '\r'}:
    dec cursor
  cursor + 1

proc conditionalLineIndent*(source: string, start, past: int): int {.inline.} =
  var cursor = start
  while cursor < past and source[cursor] in {' ', '\t'}:
    inc cursor
  cursor - start

proc conditionalLineText*(source: string, start, past: int): string =
  var first = start
  while first < past and source[first] in {' ', '\t'}:
    inc first
  var finish = past
  while finish > first and source[finish - 1] in {' ', '\t'}:
    dec finish
  if first < finish:
    result = source[first ..< finish]
