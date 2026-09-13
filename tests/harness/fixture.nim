import std/[strutils, tables]

import onim/protocol/positions

type
  CursorMarker* = object
    file*: string
    line*: int
    character*: int
    byteOffset*: int

  RangeMarker* = object
    file*: string
    startLine*: int
    startCharacter*: int
    startByteOffset*: int
    endLine*: int
    endCharacter*: int
    endByteOffset*: int

  Fixture* = object
    files*: OrderedTable[string, string]
    cursors*: seq[CursorMarker]
    ranges*: seq[RangeMarker]

  SelectionState = enum
    selectionClosed
    selectionOpen

  SelectionStart = object
    state: SelectionState
    line: int
    character: int
    byteOffset: int

proc addFile(fixture: var Fixture, path, text: string) =
  if path.len == 0:
    raise newException(ValueError, "fixture file path is empty")
  if fixture.files.hasKey(path):
    raise newException(ValueError, "duplicate fixture file: " & path)
  fixture.files[path] = text

proc flushFile(
    fixture: var Fixture, path: string, text: var string, includeEmpty: bool
) =
  if includeEmpty or text.len > 0:
    fixture.addFile(path, text)
  text.setLen(0)

proc appendLine(
    fixture: var Fixture,
    file: string,
    line: string,
    newline: string,
    lineNumber: int,
    baseOffset: int,
    selection: var SelectionStart,
): string =
  var remaining = line
  var clean = newStringOfCap(line.len)
  while true:
    var marker = remaining.find("<|>")
    var markerText = "<|>"
    for candidate in ["<sel>", "</sel>"]:
      let candidatePosition = remaining.find(candidate)
      if candidatePosition >= 0 and (marker < 0 or candidatePosition < marker):
        marker = candidatePosition
        markerText = candidate
    if marker < 0:
      clean.add remaining
      break
    let prefix = remaining[0 ..< marker]
    clean.add prefix
    let character = utf16Length(clean)
    let byteOffset = baseOffset + clean.len
    case markerText
    of "<|>":
      fixture.cursors.add CursorMarker(
        file: file, line: lineNumber, character: character, byteOffset: byteOffset
      )
    of "<sel>":
      if selection.state == selectionOpen:
        raise newException(ValueError, "nested fixture selection")
      selection = SelectionStart(
        state: selectionOpen,
        line: lineNumber,
        character: character,
        byteOffset: byteOffset,
      )
    of "</sel>":
      if selection.state != selectionOpen:
        raise newException(ValueError, "fixture selection closes before it opens")
      fixture.ranges.add RangeMarker(
        file: file,
        startLine: selection.line,
        startCharacter: selection.character,
        startByteOffset: selection.byteOffset,
        endLine: lineNumber,
        endCharacter: character,
        endByteOffset: byteOffset,
      )
      selection.state = selectionClosed
    else:
      raise newException(ValueError, "unknown fixture marker")
    let markerPast = marker + markerText.len
    remaining =
      if markerPast < remaining.len:
        remaining[markerPast .. ^1]
      else:
        ""
  result = clean & newline

proc parseFixture*(raw: string, defaultFile = "main.nim"): Fixture =
  if defaultFile.len == 0:
    raise newException(ValueError, "default fixture file path is empty")

  result.files = initOrderedTable[string, string]()
  var currentFile = defaultFile
  var currentText = newStringOfCap(raw.len)
  var currentLine = 0
  var hasSection = false
  var position = 0
  var selection = SelectionStart(state: selectionClosed)

  while position <= raw.len:
    let newlineAt = raw.find('\n', position)
    let linePast = if newlineAt < 0: raw.len else: newlineAt
    var line = raw[position ..< linePast]
    var newline = ""
    if newlineAt >= 0:
      newline = "\n"
      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
        newline = "\r\n"

    if line.startsWith("//- "):
      if selection.state == selectionOpen:
        raise newException(ValueError, "fixture selection crosses file sections")
      result.flushFile(currentFile, currentText, hasSection)
      currentLine = 0
      currentFile = line[4 .. ^1].strip()
      if currentFile.len == 0:
        raise newException(ValueError, "fixture file path is empty")
      hasSection = true
    else:
      currentText.add appendLine(
        result, currentFile, line, newline, currentLine, currentText.len, selection
      )
      inc currentLine

    if newlineAt < 0:
      break
    position = newlineAt + 1

  if hasSection or currentText.len > 0 or raw.len == 0:
    result.addFile(currentFile, currentText)
  if selection.state == selectionOpen:
    raise newException(ValueError, "fixture selection is not closed")
