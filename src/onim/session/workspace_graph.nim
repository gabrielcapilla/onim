import ./ids
import ./workspace_file_ids
import ./workspace_models

proc reverseClosure*(files: openArray[FileRecord], root: FileId): seq[FileId] =
  if not root.valid:
    return
  var seen = newSeq[bool](files.len)
  var queue = @[root]
  var head = 0
  while head < queue.len:
    let current = queue[head]
    inc head
    let index = current.recordIndex
    if index < 0 or index >= files.len or seen[index]:
      continue
    seen[index] = true
    result.add current
    for dependent in files[index].reverse:
      queue.add dependent
  result.sortIds
