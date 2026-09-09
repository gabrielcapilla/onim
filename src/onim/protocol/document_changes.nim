import std/json

import ./positions
import ./validation

proc materializeDocumentChange*(
    change: DocumentChange, source: string
): tuple[valid: bool, text: string] =
  if not change.valid or change.changes == nil or change.changes.len == 0:
    return
  if not change.changes[0].hasKey("range"):
    result.valid = true
    result.text = change.changes[0]["text"].getStr
    return

  var current = source
  for item in change.changes.items:
    let positions = initPositionIndex(current)
    let range = item["range"]
    let first = offsetAt(positions, current, range["start"])
    let past = offsetAt(positions, current, range["end"])
    if first < 0 or past < first:
      return
    var updated = newStringOfCap(current.len - (past - first) + item["text"].getStr.len)
    if first > 0:
      updated.add current[0 ..< first]
    updated.add item["text"].getStr
    if past < current.len:
      updated.add current[past .. ^1]
    current = updated
  result.valid = true
  result.text = current
