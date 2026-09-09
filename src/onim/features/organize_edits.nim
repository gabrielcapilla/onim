import std/algorithm

type ImportEdit* = object
  startOffset*: int
  endOffset*: int
  newText*: string

proc applyEdits*(source: string, edits: seq[ImportEdit]): string =
  var ordered = edits
  ordered.sort(
    proc(left, right: ImportEdit): int =
      cmp(right.startOffset, left.startOffset)
  )
  result = source
  for edit in ordered:
    if edit.startOffset < 0 or edit.endOffset < edit.startOffset or
        edit.endOffset > result.len:
      continue
    let suffix =
      if edit.endOffset < result.len:
        result[edit.endOffset .. ^1]
      else:
        ""
    result = result[0 ..< edit.startOffset] & edit.newText & suffix

proc editsDisjoint*(edits: seq[ImportEdit]): bool =
  for leftIndex in 0 ..< edits.len:
    for rightIndex in leftIndex + 1 ..< edits.len:
      let left = edits[leftIndex]
      let right = edits[rightIndex]
      if left.startOffset == left.endOffset and right.startOffset == right.endOffset:
        if left.startOffset == right.startOffset:
          return false
      elif left.startOffset == left.endOffset:
        if left.startOffset > right.startOffset and left.startOffset < right.endOffset:
          return false
      elif right.startOffset == right.endOffset:
        if right.startOffset > left.startOffset and right.startOffset < left.endOffset:
          return false
      elif max(left.startOffset, right.startOffset) <
          min(left.endOffset, right.endOffset):
        return false
  true

proc combineImportEdits*(additions, removals: seq[ImportEdit]): seq[ImportEdit] =
  var consumedAdditions = newSeq[bool](additions.len)
  for removal in removals:
    var merged = removal
    var covered = false
    for index, addition in additions:
      if consumedAdditions[index]:
        continue
      if addition.startOffset <= removal.startOffset and
          addition.endOffset >= removal.endOffset and
          addition.endOffset > addition.startOffset:
        covered = true
      elif addition.startOffset == addition.endOffset and
          addition.startOffset >= removal.startOffset and
          addition.startOffset <= removal.endOffset:
        consumedAdditions[index] = true
        if addition.startOffset == removal.endOffset:
          merged.newText.add addition.newText
        else:
          merged.newText = addition.newText & merged.newText
    if not covered:
      result.add merged
  for index, addition in additions:
    if not consumedAdditions[index]:
      result.add addition
