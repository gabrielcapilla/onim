import std/[algorithm, strutils]

import ../syntax/lexer

proc lineStart(source: string, offset: int): int {.inline.} =
  result = max(0, min(offset, source.len))
  while result > 0 and source[result - 1] != '\n':
    dec result

proc lineEnd(source: string, start: int): int {.inline.} =
  result = max(0, min(start, source.len))
  while result < source.len and source[result] != '\n':
    inc result

proc documentationLine(
    line, declarationIndent: string
): tuple[valid: bool, text: string] =
  var cursor = 0
  while cursor < line.len and line[cursor] in {' ', '\t'}:
    inc cursor
  if line[0 ..< cursor] != declarationIndent or cursor + 2 > line.len or
      line[cursor ..< cursor + 2] != "##":
    return
  var textStart = cursor + 2
  if textStart < line.len and line[textStart] == ' ':
    inc textStart
  result.valid = true
  result.text = line[textStart ..< line.len].strip

proc documentationForDeclaration*(tokens: TokenStore, nameToken: uint32): string =
  if nameToken >= uint32(tokens.len):
    return
  let token = tokens[int(nameToken)]
  if token.startOffset < 0:
    return
  let source = tokens.sourceText
  let declarationStart = lineStart(source, token.startOffset)
  var indentEnd = declarationStart
  while indentEnd < source.len and source[indentEnd] in {' ', '\t'}:
    inc indentEnd
  let declarationIndent = source[declarationStart ..< indentEnd]
  var current = declarationStart
  var lines: seq[string] = @[]
  while current > 0:
    let previousStart = lineStart(source, current - 1)
    let previousEnd = lineEnd(source, previousStart)
    let line = source[previousStart ..< previousEnd]
    let documentation = documentationLine(line, declarationIndent)
    if not documentation.valid:
      break
    lines.add documentation.text
    current = previousStart
  if lines.len == 0:
    return
  lines.reverse
  lines.join("\n")
