import std/[algorithm, os, unittest]

import onim/index/cache
import onim/index/source_index
import onim/session/paths
import onim/session/source_discovery
import harness/workspace_fs

proc writeSource(path: string) =
  createDir(splitFile(path).dir)
  writeFile(path, "discard\n")

proc manifestFor(root: string, discovery: DiscoveryResult): ProjectManifest =
  result.root = canonicalPath(root)
  result.directories = discovery.directories
  result.discoveryValid = true
  for path in discovery.paths:
    let source = readFile(path)
    result.entries.add ManifestEntry(
      path: path,
      sourceHash: contentFingerprint(source),
      byteLength: int64(source.len),
      stamp: fileStamp(path),
    )

suite "source discovery":
  test "prunes exact generated trees before descent":
    let root = getTempDir() / ("onim-discovery-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanTree(root)

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
      cleanTree(root)
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
      cleanTree(root)
    let firstPath = root / "main.nim"
    let nestedPath = root / "nested" / "module.nim"
    writeSource(firstPath)
    writeSource(nestedPath)

    let cold = discoverSources(root)
    let manifest = manifestFor(root, cold)

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

  test "fails atomically when the shared discovery budget is exhausted":
    let root = getTempDir() / ("onim-discovery-limit-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanTree(root)
    writeSource(root / "a.nim")
    writeSource(root / "b.nim")

    let exact = discoverSourcesWithLimit(root, ProjectManifest(), 4)
    check exact.status == discoveryComplete
    check exact.paths.len == 2

    let overflow = discoverSourcesWithLimit(root, ProjectManifest(), 3)
    check overflow.status == discoveryFailed
    check overflow.paths.len == 0
    check overflow.directories.len == 0

  test "cancellation takes precedence over a zero discovery budget":
    let root = getTempDir() / ("onim-discovery-cancel-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanTree(root)
    writeSource(root / "main.nim")
    let cancelled = discoverSourcesWithLimit(
      root,
      ProjectManifest(),
      0,
      proc(): bool =
        true,
    )
    check cancelled.status == discoveryCancelled
    check cancelled.paths.len == 0

  test "reuses a warm manifest within the shared budget":
    let root = getTempDir() / ("onim-discovery-warm-limit-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanTree(root)
    writeSource(root / "main.nim")
    let cold = discoverSources(root)
    let warm = discoverSourcesWithLimit(root, manifestFor(root, cold), 2)
    check warm.status == discoveryComplete
    check warm.paths == cold.paths
    check warm.entriesExamined == 0

  test "oversized warm metadata falls back to a bounded cold scan":
    let root = getTempDir() / ("onim-discovery-oversized-" & $getCurrentProcessId())
    createDir(root)
    defer:
      cleanTree(root)
    let mainPath = root / "main.nim"
    writeSource(mainPath)
    var oversized = manifestFor(root, discoverSources(root))
    for _ in 0 ..< 3:
      oversized.entries.add ManifestEntry(path: root / "not-present.nim")
    let recovered = discoverSourcesWithLimit(root, oversized, 2)
    check recovered.status == discoveryComplete
    check recovered.paths == @[canonicalPath(mainPath)]
