import std/[os, strutils]

import ../index/source_index
import ./organize
import ./organize_edits

proc organizeFile*(filePath: string, options = defaultOrganizeOptions()): bool =
  if filePath.toLowerAscii.endsWith(".nimble") or filePath.toLowerAscii.endsWith(".cfg"):
    return false
  if not fileExists(filePath):
    return false
  let source = readFile(filePath)
  let edits = organizeSourceWithIndex(filePath, source, indexSource(source), options)
  if edits.len == 0:
    return false
  let organized = applyEdits(source, edits)
  if organized == source:
    return false
  writeFile(filePath, organized)
  true
