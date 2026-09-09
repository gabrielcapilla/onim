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
