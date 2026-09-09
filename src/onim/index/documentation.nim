import std/[algorithm, strutils]

import ../syntax/tokens

proc lineStart(source: string, offset: int): int {.inline.} =
  result = max(0, min(offset, source.len))
  while result > 0 and source[result - 1] != '\n':
    dec result

proc lineEnd(source: string, start: int): int {.inline.} =
  result = max(0, min(start, source.len))
  while result < source.len and source[result] != '\n':
    inc result

proc documentationLine(
    line, declarationIndent: string, includeOrdinary = false
): tuple[valid: bool, text: string] =
  var cursor = 0
  while cursor < line.len and line[cursor] in {' ', '\t'}:
    inc cursor
  if line[0 ..< cursor] != declarationIndent:
    return
  var textStart = cursor
  if cursor + 2 <= line.len and line[cursor ..< cursor + 2] == "##":
    textStart += 2
  elif includeOrdinary and cursor < line.len and line[cursor] == '#':
    inc textStart
  else:
    return
  if textStart < line.len and line[textStart] == ' ':
    inc textStart
  result.valid = true
  result.text = line[textStart ..< line.len].strip

proc nextLineStart(source: string, linePast: int): int {.inline.} =
  result = min(max(linePast, 0), source.len)
  while result < source.len and source[result] in {'\r', '\n'}:
    inc result

proc bodyDocumentation(
    source, declarationIndent: string, declarationStart: int
): string =
  var current = nextLineStart(source, lineEnd(source, declarationStart))
  if current >= source.len:
    return
  let firstPast = lineEnd(source, current)
  var bodyIndentEnd = current
  while bodyIndentEnd < firstPast and source[bodyIndentEnd] in {' ', '\t'}:
    inc bodyIndentEnd
  if bodyIndentEnd - current <= declarationIndent.len:
    return
  let bodyIndent = source[current ..< bodyIndentEnd]
  var lines: seq[string] = @[]
  while current < source.len:
    let past = lineEnd(source, current)
    let documentation =
      documentationLine(source[current ..< past], bodyIndent, includeOrdinary = true)
    if not documentation.valid:
      break
    lines.add documentation.text
    current = nextLineStart(source, past)
  if lines.len > 0:
    result = lines.join("\n")

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
    return bodyDocumentation(source, declarationIndent, declarationStart)
  lines.reverse
  lines.join("\n")
