import std/[algorithm, osproc, strutils, unittest]
import std/os except FileId

import onim/index/cache
import onim/index/source_index
import onim/session/ids
import onim/session/workspace

proc uriFor(path: string): string =
  "file://" & path.replace('\\', '/')

proc sameId(left, right: FileId): bool =
  left.value == right.value

proc hasId(values: openArray[FileId], wanted: FileId): bool =
  for value in values:
    if value.sameId(wanted):
      return true

proc sortedUnique(values: openArray[FileId]): bool =
  for index in 1 ..< values.len:
    if values[index - 1].value >= values[index].value:
      return false
  true

proc cleanRoot(root: string) =
  if not dirExists(root):
    return
  for path in walkDirRec(root):
    if fileExists(path):
      removeFile(path)
  removeDir(root)

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

suite "workspace index":
  test "persists and reloads source indexes":
    let root = getTempDir() / ("onim-cache-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let filePath = root / "cached.nim"
    let source = "import std/os\nfor kind, path in walkDir(\"/tmp\"):\n  discard kind\n"
    writeFile(filePath, source)

    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let firstWorkspace = initWorkspace(root)
    firstWorkspace.indexWorkspace()
    let firstId = firstWorkspace.fileIdForPath(filePath)
    let firstSnapshot = firstWorkspace.snapshotForFile(firstId)
    let path = cacheFilePath(root, filePath)
    let manifestPath = projectManifestPath(root)
    check fileExists(path)
    check fileExists(manifestPath)
    check firstWorkspace.manifest.root == absolutePath(root)
    check firstWorkspace.manifest.entries.len == 1
    check firstWorkspace.manifest.entries[0].path == absolutePath(filePath)
    check firstSnapshot.index != nil
    check loadCachedSourceIndex(root, filePath, source) != nil
    check loadCachedSourceIndexFingerprint(
      root, filePath, contentFingerprint(source), source.len
    ) != nil
    check loadCachedSourceIndex(root, filePath, source & "# changed\n") == nil
    var invalidGraphEntry = firstWorkspace.manifest.entries[0]
    invalidGraphEntry.forwardOrdinals = @[1'u32]
    check not saveProjectManifest(root, @[invalidGraphEntry], graphValid = true)

    let secondWorkspace = initWorkspace(root)
    secondWorkspace.indexWorkspace()
    let secondSnapshot =
      secondWorkspace.snapshotForFile(secondWorkspace.fileIdForPath(filePath))
    check secondWorkspace.manifest.entries.len == 1
    check secondWorkspace.manifest.entries[0].sourceHash ==
      firstWorkspace.manifest.entries[0].sourceHash
    check secondSnapshot.index != nil
    check secondSnapshot.index.contentHash == firstSnapshot.index.contentHash
    check secondSnapshot.index.tokenCount == firstSnapshot.index.tokenCount
    check secondSnapshot.index.parsed.tokens == firstSnapshot.index.parsed.tokens
    check secondSnapshot.index.parsed.imports.len ==
      firstSnapshot.index.parsed.imports.len

    let cacheBytes = readFile(path)
    writeFile(path, cacheBytes & "trailing")
    check loadCachedSourceIndex(root, filePath, source) == nil
    writeFile(path, "corrupt")
    check loadCachedSourceIndex(root, filePath, source) == nil

    let manifestBytes = readFile(manifestPath)
    writeFile(manifestPath, manifestBytes & "trailing")
    check loadProjectManifest(root).entries.len == 0

  test "reconciles deleted and recreated modules":
    let root = getTempDir() / ("onim-reconcile-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-reconcile-cache-" & $getCurrentProcessId())
    cleanRoot(root)
    cleanTree(cacheRoot)
    createDir(root)
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanRoot(root)
      cleanTree(cacheRoot)

    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "proc provided() = discard\n")
    writeFile(consumerPath, "import provider\nprovided()\n")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    let providerId = workspace.fileIdForPath(providerPath)
    let consumerId = workspace.fileIdForPath(consumerPath)
    check workspace.dependencies(consumerId).hasId(providerId)
    check workspace.graphComplete
    check workspace.manifest.graphValid
    discard workspace.drainInvalidated()

    let warmWorkspace = initWorkspace(root)
    warmWorkspace.indexWorkspace()
    let warmProviderId = warmWorkspace.fileIdForPath(providerPath)
    let warmConsumerId = warmWorkspace.fileIdForPath(consumerPath)
    check warmWorkspace.manifest.graphValid
    check warmWorkspace.dependencies(warmConsumerId).hasId(warmProviderId)
    check warmWorkspace.graphComplete

    removeFile(providerPath)
    workspace.indexWorkspace()
    check workspace.snapshotForFile(providerId).state == workspaceMissing
    check workspace.dependencies(consumerId).len == 0
    check not workspace.graphComplete
    discard workspace.drainInvalidated()

    writeFile(providerPath, "proc provided() = discard\n")
    workspace.fileChanged(providerPath)
    check workspace.snapshotForFile(providerId).state == workspaceOnDisk
    check workspace.dependencies(consumerId).hasId(providerId)
    check workspace.graphComplete

  test "indexes dependencies and invalidates reverse closure":
    let root = getTempDir() / ("onim-workspace-" & $getCurrentProcessId())
    cleanRoot(root)
    createDir(root)
    defer:
      cleanRoot(root)

    let aPath = root / "a.nim"
    let bPath = root / "b.nim"
    let cPath = root / "c.nim"
    let dPath = root / "d.nim"
    let ePath = root / "e.nim"
    let exporterPath = root / "exporter.nim"
    let includeParentPath = root / "include_parent.nim"
    let includedPath = root / "included.nim"
    let cycleOnePath = root / "cycle1.nim"
    let cycleTwoPath = root / "cycle2.nim"

    let cText = "proc c() = discard\n"
    writeFile(aPath, "import b\nimport c\n")
    writeFile(bPath, "import c\n")
    writeFile(cPath, cText)
    writeFile(dPath, "import c\n")
    writeFile(ePath, "import b\nimport d\n")
    writeFile(exporterPath, "import c\nexport c\n")
    writeFile(includeParentPath, "include included\n")
    writeFile(includedPath, "const includedValue = 1\n")
    writeFile(cycleOnePath, "import cycle2\n")
    writeFile(cycleTwoPath, "import cycle1\n")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.fileCount == 10
    check workspace.graphComplete
    check workspace.drainInvalidated().len == 0

    let aId = workspace.fileIdForPath(aPath)
    let bId = workspace.fileIdForPath(bPath)
    let cId = workspace.fileIdForPath(cPath)
    let dId = workspace.fileIdForPath(dPath)
    let eId = workspace.fileIdForPath(ePath)
    let exporterId = workspace.fileIdForPath(exporterPath)
    let includeParentId = workspace.fileIdForPath(includeParentPath)
    let includedId = workspace.fileIdForPath(includedPath)
    let cycleOneId = workspace.fileIdForPath(cycleOnePath)
    let cycleTwoId = workspace.fileIdForPath(cycleTwoPath)

    check aId.valid
    check workspace.dependencies(aId).len == 2
    check workspace.dependencies(aId).hasId(bId)
    check workspace.dependencies(aId).hasId(cId)
    check workspace.dependencies(exporterId).len == 1
    check workspace.dependencies(exporterId).hasId(cId)
    check workspace.dependencies(includeParentId).len == 1
    check workspace.dependencies(includeParentId).hasId(includedId)

    let cDependents = workspace.dependents(cId)
    check cDependents.len == 4
    check cDependents.hasId(aId)
    check cDependents.hasId(bId)
    check cDependents.hasId(dId)
    check cDependents.hasId(exporterId)
    check sortedUnique(cDependents)

    let includedDependents = workspace.dependents(includedId)
    check includedDependents.len == 1
    check includedDependents.hasId(includeParentId)

    let opened = workspace.openDocument(uriFor(cPath), cPath, cText, 1)
    check opened.sameId(cId)
    check workspace.drainInvalidated().len == 0
    check workspace.changeDocument(uriFor(cPath), cPath, cText, 2)
    check workspace.drainInvalidated().len == 0

    let beforeChange = workspace.snapshotForFile(cId)
    check not workspace.changeDocument(
      uriFor(cPath), cPath, "proc changed() = discard\n", 1
    )
    check workspace.drainInvalidated().len == 0
    check workspace.changeDocument(
      uriFor(cPath), cPath, "proc changed() = discard\n", 3
    )
    let changed = workspace.drainInvalidated()
    check changed.len == 6
    check sortedUnique(changed)
    check changed.hasId(cId)
    check changed.hasId(aId)
    check changed.hasId(bId)
    check changed.hasId(dId)
    check changed.hasId(eId)
    check changed.hasId(exporterId)
    check workspace.snapshotForFile(cId).contentGeneration.value !=
      beforeChange.contentGeneration.value

    workspace.indexWorkspace()
    let overlay = workspace.snapshotForFile(cId)
    check overlay.state == workspaceOpen
    check overlay.text == "proc changed() = discard\n"

    workspace.closeDocument(uriFor(cPath), cPath)
    let closed = workspace.snapshotForFile(cId)
    check closed.valid
    check closed.state == workspaceOnDisk
    check closed.text == cText
    check workspace.drainInvalidated().len == 6

    check workspace.changeDocument(
      uriFor(cycleOnePath), cycleOnePath, "import cycle2\n# changed\n", 1
    )
    let cycleAffected = workspace.drainInvalidated()
    check cycleAffected.len == 2
    check cycleAffected.sortedUnique
    check cycleAffected.hasId(cycleOneId)
    check cycleAffected.hasId(cycleTwoId)

    let unresolvedPath = root / "unresolved.nim"
    writeFile(unresolvedPath, "import missing/submodule\n")
    workspace.fileChanged(unresolvedPath)
    let unresolvedId = workspace.fileIdForPath(unresolvedPath)
    check unresolvedId.valid
    check not workspace.graphComplete
    discard workspace.drainInvalidated()

    check workspace.changeDocument(
      uriFor(aPath), aPath, "import b\nimport c\n# changed\n", 1
    )
    let conservative = workspace.drainInvalidated()
    check conservative.len == workspace.fileCount
    check conservative.sortedUnique

    removeFile(unresolvedPath)
    workspace.fileChanged(unresolvedPath, deleted = true)
    check unresolvedId.sameId(workspace.fileIdForPath(unresolvedPath))
    check workspace.graphComplete
    discard workspace.drainInvalidated()

    workspace.configurationChanged()
    let configAffected = workspace.drainInvalidated()
    check configAffected.len == workspace.fileCount
    check configAffected.sortedUnique
