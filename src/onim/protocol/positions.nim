import std/json

type PositionIndex* = object
  lineStarts: seq[int]

proc intOption(node: JsonNode, key: string, fallback: int64): int64 =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    int64(node[key].getInt)
  else:
    fallback

proc utf16Width(source: string, index, limit: int): tuple[nextIndex, units: int] =
  let first = ord(source[index])
  var codepoint = first
  var width = 1
  if (first and 0xE0) == 0xC0 and index + 1 < limit and
      (ord(source[index + 1]) and 0xC0) == 0x80:
    codepoint = ((first and 0x1F) shl 6) or (ord(source[index + 1]) and 0x3F)
    width = 2
  elif (first and 0xF0) == 0xE0 and index + 2 < limit and
      (ord(source[index + 1]) and 0xC0) == 0x80 and
      (ord(source[index + 2]) and 0xC0) == 0x80:
    codepoint =
      ((first and 0x0F) shl 12) or ((ord(source[index + 1]) and 0x3F) shl 6) or
      (ord(source[index + 2]) and 0x3F)
    width = 3
  elif (first and 0xF8) == 0xF0 and index + 3 < limit and
      (ord(source[index + 1]) and 0xC0) == 0x80 and
      (ord(source[index + 2]) and 0xC0) == 0x80 and
      (ord(source[index + 3]) and 0xC0) == 0x80:
    codepoint =
      ((first and 0x07) shl 18) or ((ord(source[index + 1]) and 0x3F) shl 12) or
      ((ord(source[index + 2]) and 0x3F) shl 6) or (ord(source[index + 3]) and 0x3F)
    width = 4
  (min(limit, index + width), if codepoint > 0xFFFF: 2 else: 1)

proc initPositionIndex*(source: string): PositionIndex =
  result.lineStarts = @[0]
  for offset, character in source:
    if character == '\n':
      result.lineStarts.add offset + 1

proc lineAt(index: PositionIndex, offset: int): int {.inline.} =
  var low = 0
  var high = index.lineStarts.high
  while low <= high:
    let middle = (low + high) shr 1
    if index.lineStarts[middle] <= offset:
      low = middle + 1
    else:
      high = middle - 1
  max(0, low - 1)

proc positionAt*(index: PositionIndex, source: string, offset: int): JsonNode =
  var column = 0
  let limit = max(0, min(offset, source.len))
  let line = index.lineAt(limit)
  var cursor = index.lineStarts[line]
  while cursor < limit:
    let advance = utf16Width(source, cursor, limit)
    cursor = advance.nextIndex
    column += advance.units
  %*{"line": line, "character": column}

proc positionAt*(source: string, offset: int): JsonNode =
  positionAt(initPositionIndex(source), source, offset)

proc offsetAt*(index: PositionIndex, source: string, position: JsonNode): int =
  if position == nil or position.kind != JObject:
    return -1
  let lineValue = intOption(position, "line", -1)
  let characterValue = intOption(position, "character", -1)
  if lineValue < 0 or characterValue < 0 or lineValue > int64(high(int)) or
      characterValue > int64(high(int)):
    return -1
  let wantedLine = int(lineValue)
  let wantedCharacter = int(characterValue)
  if wantedLine >= index.lineStarts.len:
    return -1

  let lineStart = index.lineStarts[wantedLine]
  var lineEnd = lineStart
  while lineEnd < source.len and source[lineEnd] != '\n':
    inc lineEnd
  var character = 0
  var cursor = lineStart
  while cursor < lineEnd:
    if character == wantedCharacter:
      return cursor
    let advance = utf16Width(source, cursor, lineEnd)
    if character + advance.units > wantedCharacter:
      return -1
    character += advance.units
    cursor = advance.nextIndex
  if character == wantedCharacter: cursor else: -1

proc offsetAt*(source: string, position: JsonNode): int =
  offsetAt(initPositionIndex(source), source, position)

proc utf16Length*(value: string): int =
  var index = 0
  while index < value.len:
    let advance = utf16Width(value, index, value.len)
    result += advance.units
    index = advance.nextIndex
