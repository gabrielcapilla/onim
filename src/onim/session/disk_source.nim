import std/os

import ../index/cache
import ../index/source_index

proc unknownStamp*(): FileStamp =
  FileStamp(size: -1, modifiedSeconds: -1, modifiedNanoseconds: -1)

proc stableDiskSource*(
    path: string
): tuple[valid: bool, source: string, stamp: FileStamp] =
  for _ in 0 .. 1:
    let before = fileStamp(path)
    if before.size < 0:
      return
    try:
      let source = readFile(path)
      let after = fileStamp(path)
      if sameFileStamp(before, after) and after.size == int64(source.len):
        return (true, source, after)
    except CatchableError:
      return

proc indexDiskSource*(root, path, source: string): SourceIndex =
  result = loadCachedSourceIndex(root, path, source)
  if result == nil:
    result = indexSource(source)
    discard saveCachedSourceIndex(root, path, source, result)
