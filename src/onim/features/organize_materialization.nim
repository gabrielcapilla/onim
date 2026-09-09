import std/[hashes, os]

proc pathForSource*(filePath, source: string): tuple[path: string, temporary: bool] =
  if filePath.len > 0 and fileExists(filePath):
    try:
      if readFile(filePath) == source:
        return (filePath, false)
    except CatchableError:
      discard
  var directory = splitFile(filePath).dir
  if directory.len == 0:
    directory = getCurrentDir()
  let base = splitFile(filePath).name
  let identity =
    if filePath.len > 0:
      absolutePath(filePath)
    else:
      base
  let suffix = $abs(hash(identity))
  let temporary = directory / ("." & base & ".onim-" & suffix & ".nim")
  try:
    writeFile(temporary, source)
    (temporary, true)
  except CatchableError:
    (filePath, false)
