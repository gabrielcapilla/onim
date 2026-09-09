import std/algorithm

import ./ids

proc recordIndex*(id: FileId): int =
  id.slot

proc validRecordIndex*(id: FileId, count: int): bool =
  let index = id.recordIndex
  index >= 0 and index < count

proc addUniqueId*(values: var seq[FileId], value: FileId) =
  if not value.valid:
    return
  for existing in values:
    if uint32(existing) == uint32(value):
      return
  values.add value

proc sortIds*(values: var seq[FileId]) =
  values.sort(
    proc(left, right: FileId): int =
      cmp(uint32(left), uint32(right))
  )

proc removeId*(values: var seq[FileId], value: FileId) =
  var writeIndex = 0
  for current in values:
    if uint32(current) != uint32(value):
      values[writeIndex] = current
      inc writeIndex
  values.setLen(writeIndex)
