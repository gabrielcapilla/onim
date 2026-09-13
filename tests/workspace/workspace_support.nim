import std/strutils

import onim/session/ids

proc uriFor*(path: string): string =
  "file://" & path.replace('\\', '/')

proc sameId*(left, right: FileId): bool =
  left.value == right.value

proc hasId*(values: openArray[FileId], wanted: FileId): bool =
  for value in values:
    if value.sameId(wanted):
      return true

proc sortedUnique*(values: openArray[FileId]): bool =
  for index in 1 ..< values.len:
    if values[index - 1].value >= values[index].value:
      return false
  true

proc replaceLine*(source: string, line: int, name: string): string =
  var lines = source.splitLines()
  lines[line] = "echo " & name
  lines.join("\n")
