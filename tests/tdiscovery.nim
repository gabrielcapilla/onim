import std/[algorithm, os, unittest]

import onim/index/cache
import onim/index/source_index
import onim/session/paths
import onim/session/source_discovery

proc writeSource(path: string) =
  createDir(splitFile(path).dir)
  writeFile(path, "discard\n")

proc cleanup(root: string) =
  var entries: seq[string] = @[]
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    entries.add path
  entries.sort(
    proc(left, right: string): int =
      cmp(right.len, left.len)
  )
  for path in entries:
    if fileExists(path):
      removeFile(path)
    elif dirExists(path):
      removeDir(path)
  if dirExists(root):
    removeDir(root)

suite "source discovery":
  test "prunes exact generated trees before descent":
    let root = getTempDir() / ("onim-discovery-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanup(root)

    for directory in [
      root / ".git" / "deep",
      root / ".cache" / "deep",
      root / "nimcache" / "deep",
      root / ".github",
      root / ".hidden",
      root / "my.cache",
      root / "nimcache2",
    ]:
      createDir(directory)
    for path in [
      root / "main.nim",
      root / ".github" / "ci.nim",
      root / ".hidden" / "keep.nim",
      root / "my.cache" / "keep.nim",
      root / "nimcache2" / "keep.nim",
      root / ".nimcache" / "keep.nim",
      root / ".git" / "deep" / "ignored.nim",
      root / ".cache" / "deep" / "ignored.nim",
      root / "nimcache" / "deep" / "ignored.nim",
    ]:
      writeSource(path)

    let discovered = discoverSources(root)
    var expected: seq[string] = @[]
    for path in [
      root / ".github" / "ci.nim",
      root / ".hidden" / "keep.nim",
      root / "main.nim",
      root / "my.cache" / "keep.nim",
      root / "nimcache2" / "keep.nim",
      root / ".nimcache" / "keep.nim",
    ]:
      expected.add canonicalPath(path)
    expected.sort
    check discovered.status == discoveryComplete
    check discovered.paths == expected
    check discovered.directoriesPruned == 3
    check discovered.directoriesVisited == 6
    check discovered.entriesExamined == 14

  test "returns deterministic sorted paths":
    let root = getTempDir() / ("onim-discovery-sorted-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanup(root)
    for path in [root / "z.nim", root / "a.nim", root / "nested" / "m.nim"]:
      writeSource(path)
    let first = discoverSources(root)
    let second = discoverSources(root)
    check first.status == discoveryComplete
    check first.paths == second.paths

  test "reuses directory manifest and refreshes changed parents":
    let root = getTempDir() / ("onim-discovery-manifest-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanup(root)
    let firstPath = root / "main.nim"
    let nestedPath = root / "nested" / "module.nim"
    writeSource(firstPath)
    writeSource(nestedPath)

    let cold = discoverSources(root)
    var entries: seq[ManifestEntry] = @[]
    for path in cold.paths:
      entries.add ManifestEntry(
        path: path,
        sourceHash: contentFingerprint(readFile(path)),
        byteLength: int64(readFile(path).len),
        stamp: fileStamp(path),
      )
    let manifest = ProjectManifest(
      root: canonicalPath(root),
      entries: entries,
      directories: cold.directories,
      discoveryValid: true,
    )

    let warm = discoverSources(root, manifest)
    check warm.status == discoveryComplete
    check warm.paths == cold.paths
    check warm.entriesExamined == 0
    check warm.directoriesReused == uint32(cold.directories.len)

    let nestedAddedPath = root / "nested" / "added.nim"
    writeSource(nestedAddedPath)
    var changed = manifest
    for index, directory in changed.directories:
      if directory.path == canonicalPath(root / "nested"):
        changed.directories[index].stamp.modifiedNanoseconds =
          if directory.stamp.modifiedNanoseconds == 999_999_999:
            0
          else:
            directory.stamp.modifiedNanoseconds + 1
    let refreshed = discoverSources(root, changed)
    check refreshed.status == discoveryComplete
    check canonicalPath(nestedAddedPath) in refreshed.paths

    let addedPath = root / "added.nim"
    writeSource(addedPath)
    var changedRoot = manifest
    for index, directory in changedRoot.directories:
      if directory.path == canonicalPath(root):
        changedRoot.directories[index].stamp.modifiedNanoseconds =
          if directory.stamp.modifiedNanoseconds == 999_999_999:
            0
          else:
            directory.stamp.modifiedNanoseconds + 1
    let rootRefreshed = discoverSources(root, changedRoot)
    check rootRefreshed.status == discoveryComplete
    check canonicalPath(addedPath) in rootRefreshed.paths
