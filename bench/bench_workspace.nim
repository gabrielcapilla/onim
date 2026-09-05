import std/[algorithm, monotimes, os, times]

import onim/session/workspace

const moduleCount = 256

proc cleanTree(root: string) =
  if not dirExists(root):
    return
  var directories: seq[string] = @[]
  for path in walkDirRec(root):
    if fileExists(path):
      removeFile(path)
    elif dirExists(path):
      directories.add path
  directories.sort(
    proc(left, right: string): int =
      cmp(right.len, left.len)
  )
  for path in directories:
    if dirExists(path):
      removeDir(path)
  if dirExists(root):
    removeDir(root)

let root = getTempDir() / ("onim-workspace-bench-" & $getCurrentProcessId())
let cacheRoot = getTempDir() / ("onim-workspace-cache-" & $getCurrentProcessId())
cleanTree(root)
cleanTree(cacheRoot)
createDir(root)
let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
putEnv("ONIM_CACHE_DIR", cacheRoot)

for index in 0 ..< moduleCount:
  let moduleName = "module" & $index
  let dependency =
    if index == 0:
      ""
    else:
      "import module" & $(index - 1) & "\n"
  writeFile(root / (moduleName & ".nim"), dependency & "proc value*() = discard\n")

let coldWorkspace = initWorkspace(root)
let coldStarted = getMonoTime()
coldWorkspace.indexWorkspace()
let coldNanoseconds = (getMonoTime() - coldStarted).inNanoseconds

let warmWorkspace = initWorkspace(root)
let warmStarted = getMonoTime()
warmWorkspace.indexWorkspace()
let warmNanoseconds = (getMonoTime() - warmStarted).inNanoseconds
let surfaceStarted = getMonoTime()
discard warmWorkspace.projectSurface()
let surfaceNanoseconds = (getMonoTime() - surfaceStarted).inNanoseconds
let cachedSurfaceStarted = getMonoTime()
discard warmWorkspace.projectSurface()
let cachedSurfaceNanoseconds = (getMonoTime() - cachedSurfaceStarted).inNanoseconds
let editPath = root / "module127.nim"
let editSource = readFile(editPath) & "proc extra*() = discard\n"
let editStarted = getMonoTime()
discard warmWorkspace.changeDocument("", editPath, editSource, 1)
let editNanoseconds = (getMonoTime() - editStarted).inNanoseconds
let rebuildStarted = getMonoTime()
discard warmWorkspace.projectSurface()
let rebuildNanoseconds = (getMonoTime() - rebuildStarted).inNanoseconds

let lazyWorkspace = initWorkspace()
let prepareStarted = getMonoTime()
discard lazyWorkspace.prepareWorkspace(root)
let prepareNanoseconds = (getMonoTime() - prepareStarted).inNanoseconds
let bootstrapStarted = getMonoTime()
discard lazyWorkspace.bootstrapWorkspace()
let bootstrapNanoseconds = (getMonoTime() - bootstrapStarted).inNanoseconds

echo "modules=",
  moduleCount,
  " cold_ms=",
  coldNanoseconds.float / 1_000_000,
  " warm_ms=",
  warmNanoseconds.float / 1_000_000,
  " surface_ms=",
  surfaceNanoseconds.float / 1_000_000,
  " cached_surface_ms=",
  cachedSurfaceNanoseconds.float / 1_000_000,
  " edit_ms=",
  editNanoseconds.float / 1_000_000,
  " rebuild_ms=",
  rebuildNanoseconds.float / 1_000_000,
  " prepare_ms=",
  prepareNanoseconds.float / 1_000_000,
  " bootstrap_ms=",
  bootstrapNanoseconds.float / 1_000_000,
  " graph_complete=",
  warmWorkspace.graphComplete

if previousCacheRoot.len > 0:
  putEnv("ONIM_CACHE_DIR", previousCacheRoot)
else:
  delEnv("ONIM_CACHE_DIR")
cleanTree(root)
cleanTree(cacheRoot)
