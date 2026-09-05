import std/[algorithm, strutils, unittest]
import std/os except FileId

import onim/index/cache
import onim/index/occurrences
import onim/index/scopes
import onim/index/source_index
import onim/index/surfaces
import onim/session/ids
import onim/session/workspace
import onim/syntax/lexer

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

proc replaceLine(source: string, line: int, name: string): string =
  var lines = source.splitLines()
  lines[line] = "echo " & name
  lines.join("\n")

suite "workspace index":
  test "token store preserves logical order with copy-on-write blocks":
    var expected = newSeq[Token](tokenBlockLength * 2 + 1)
    for index in 0 ..< expected.len:
      expected[index] = Token(
        kind: tkIdentifier,
        text: "token" & $index,
        startOffset: index,
        endOffset: index + 1,
        line: index,
        column: 0,
      )
    let empty = initTokenStore(newSeq[Token]())
    check empty.len == 0
    check empty.high == -1
    var boundsRaised = false
    try:
      discard empty[0]
    except IndexDefect:
      boundsRaised = true
    check boundsRaised
    let one = initTokenStore(@[expected[0]])
    check one.len == 1
    check one[0] == expected[0]
    let base = initTokenStore(expected)
    check base.len == expected.len
    check base.high == expected.high
    check base == expected
    check base.toSeq == expected

    var changed = base[tokenBlockLength]
    changed.text = "middle"
    let middle = base.withToken(tokenBlockLength, changed)
    check base[tokenBlockLength].text == "token" & $tokenBlockLength
    check middle[tokenBlockLength].text == "middle"
    check middle[0] == base[0]
    check middle[middle.high] == base[base.high]

    changed = middle[tokenBlockLength]
    changed.text = "center"
    let repeated = middle.withToken(tokenBlockLength, changed)
    check middle[tokenBlockLength].text == "middle"
    check repeated[tokenBlockLength].text == "center"

    changed = repeated[repeated.high]
    changed.text = "last"
    let last = repeated.withToken(repeated.high, changed)
    check repeated[repeated.high].text == "token" & $(expected.high)
    check last[last.high].text == "last"
    check last[tokenBlockLength].text == "center"
    check last.toSeq[tokenBlockLength].text == "center"

  test "persists and reloads source indexes":
    let root = getTempDir() / ("onim-cache-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let filePath = root / "cached.nim"
    let source =
      "import std/os\nproc listFiles(dir: string) =\n  discard walkDir(dir)\n"
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
    check firstWorkspace.manifest.discoveryValid
    check firstWorkspace.manifest.directories.len > 0
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
    check secondWorkspace.manifest.discoveryValid
    check secondWorkspace.manifest.directories.len ==
      firstWorkspace.manifest.directories.len
    check secondWorkspace.manifest.entries[0].sourceHash ==
      firstWorkspace.manifest.entries[0].sourceHash
    check secondSnapshot.index != nil
    check secondSnapshot.index.contentHash == firstSnapshot.index.contentHash
    check secondSnapshot.index.tokenCount == firstSnapshot.index.tokenCount
    check secondSnapshot.index.parsed.tokens == firstSnapshot.index.parsed.tokens
    check secondSnapshot.index.parsed.imports.len ==
      firstSnapshot.index.parsed.imports.len
    check secondSnapshot.index.symbols == firstSnapshot.index.symbols
    check secondSnapshot.index.scopes == firstSnapshot.index.scopes
    check secondSnapshot.index.scopes.validateScopes(
      secondSnapshot.index.parsed.tokens, secondSnapshot.index.symbols,
      secondSnapshot.index.byteLength,
    )
    check secondSnapshot.index.occurrences == firstSnapshot.index.occurrences
    check secondSnapshot.index.occurrences.validateOccurrences(
      secondSnapshot.index.parsed.tokens
    )

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

  test "caches and invalidates the project surface":
    let root = getTempDir() / ("onim-surface-workspace-" & $getCurrentProcessId())
    cleanRoot(root)
    createDir(root)
    defer:
      cleanRoot(root)

    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "proc provided*() = discard\n")
    writeFile(consumerPath, "import provider\nproc main() =\n  discard provided()\n")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let first = workspace.projectSurface()
    check first.valid
    check first.universeIsComplete
    check first.lookupInModule("provider", "provided").kind == surfaceResolved
    check workspace.projectSurface() == first

    workspace.configurationChanged()
    let configured = workspace.projectSurface()
    check configured != first
    check configured.lookupInModule("provider", "provided").kind == surfaceResolved

    writeFile(providerPath, "proc changed*() = discard\n")
    workspace.fileChanged(providerPath)
    let second = workspace.projectSurface()
    check second.lookupInModule("provider", "provided").kind == surfaceUnresolved
    check second.lookupInModule("provider", "changed").kind == surfaceResolved

  test "resolves conventional and Nimble import roots":
    let root = getTempDir() / ("onim-import-roots-" & $getCurrentProcessId())
    cleanRoot(root)
    createDir(root)
    createDir(root / "src")
    createDir(root / "lib")
    defer:
      cleanRoot(root)

    let mainPath = root / "main.nim"
    let standardPath = root / "src" / "standard.nim"
    let providerPath = root / "lib" / "provider.nim"
    let packagePath = root / "package.nimble"
    writeFile(packagePath, "srcDir = \"lib\"\n")
    writeFile(mainPath, "import provider\nprovider.answer()\n")
    writeFile(standardPath, "proc standard*() = discard\n")
    writeFile(providerPath, "proc answer*() = discard\n")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    let mainId = workspace.fileIdForPath(mainPath)
    let providerId = workspace.fileIdForPath(providerPath)
    check mainId.valid
    check providerId.valid
    check workspace.dependencies(mainId).hasId(providerId)
    check workspace.moduleForPath(standardPath) == "standard"
    check workspace.moduleForPath(providerPath) == "provider"
    check workspace.projectSurface().lookupInModule("provider", "answer").kind ==
      surfaceResolved

    removeFile(packagePath)
    workspace.fileChanged(packagePath, deleted = true)
    check workspace.dependencies(mainId).len == 0
    check not workspace.graphComplete

    writeFile(packagePath, "srcDir = \"lib\"\n")
    workspace.fileChanged(packagePath)
    check workspace.dependencies(mainId).hasId(providerId)
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
    check conservative.len == 2
    check conservative.sortedUnique
    check conservative.hasId(aId)
    check conservative.hasId(unresolvedId)

    removeFile(unresolvedPath)
    workspace.fileChanged(unresolvedPath, deleted = true)
    check unresolvedId.sameId(workspace.fileIdForPath(unresolvedPath))
    check workspace.graphComplete
    discard workspace.drainInvalidated()

    workspace.configurationChanged()
    let configAffected = workspace.drainInvalidated()
    check configAffected.len == workspace.fileCount
    check configAffected.sortedUnique

  test "defers bootstrap and preserves partial workspace state":
    let root = getTempDir() / ("onim-lazy-workspace-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-lazy-workspace-cache-" & $getCurrentProcessId())
    cleanRoot(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let providerSource = "proc answer*() = discard\n"
    let consumerSource = "import provider\nprovider.answer()\n"
    let overlaySource = "import provider\nprovider.answer()\n# overlay\n"
    writeFile(providerPath, providerSource)
    writeFile(consumerPath, consumerSource)

    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanRoot(root)
      cleanTree(cacheRoot)

    let prepared = initWorkspace(root)
    prepared.indexWorkspace()
    let manifestPath = projectManifestPath(root)
    let manifestBytes = readFile(manifestPath)

    let workspace = initWorkspace()
    check workspace.prepareWorkspace(root)
    check workspace.bootstrapState == workspaceBootstrapPending
    check not workspace.graphComplete
    let consumerId =
      workspace.openDocument(uriFor(consumerPath), consumerPath, overlaySource, 1)
    workspace.fileChanged(providerPath)
    let providerId = workspace.fileIdForPath(providerPath)
    check providerId.valid
    check workspace.bootstrapState == workspaceBootstrapIncomplete
    check readFile(manifestPath) == manifestBytes

    check workspace.bootstrapWorkspace()
    check workspace.bootstrapState == workspaceBootstrapComplete
    check workspace.graphComplete
    check workspace.fileIdForPath(providerPath).value == providerId.value
    check workspace.snapshotForFile(consumerId).state == workspaceOpen
    check workspace.snapshotForFile(consumerId).text == overlaySource
    check workspace.dependencies(consumerId).hasId(providerId)
    check readFile(manifestPath) == manifestBytes
    check workspace.bootstrapWorkspace()

    let failed = initWorkspace()
    check failed.prepareWorkspace(root / "missing")
    check not failed.bootstrapWorkspace()
    check failed.bootstrapState == workspaceBootstrapFailed
    check not failed.bootstrapWorkspace()

  test "incrementally reindexes same-line references":
    let oldSource = "let value = 1\necho value\n"
    let newSource = "let value = 1\necho other\n"
    let oldIndex = indexSource(oldSource)
    let incremental = tryIndexSourceIncremental(oldSource, oldIndex, newSource)
    let rebuilt = indexSource(newSource)
    check incremental != nil
    check incremental.contentHash == rebuilt.contentHash
    check incremental.byteLength == rebuilt.byteLength
    check incremental.tokenCount == rebuilt.tokenCount
    check incremental.parsed.tokens == rebuilt.parsed.tokens
    check incremental.parsed.imports == rebuilt.parsed.imports
    check incremental.symbols == rebuilt.symbols
    check incremental.scopes == rebuilt.scopes
    check incremental.occurrences == rebuilt.occurrences
    check incremental.imports == rebuilt.imports
    check incremental.exports == rebuilt.exports
    check incremental.includes == rebuilt.includes
    check incremental.scopes.validateScopes(
      incremental.parsed.tokens, incremental.symbols, incremental.byteLength
    )
    check incremental.occurrences.validateOccurrences(incremental.parsed.tokens)

    check tryIndexSourceIncremental(oldSource, oldIndex, "let value = 1\necho other!\n") ==
      nil
    check tryIndexSourceIncremental(
      oldSource, oldIndex, "let value = 1\necho value\n# edit\n"
    ) == nil
    check tryIndexSourceIncremental(
      "import std/os\necho value\n",
      indexSource("import std/os\necho value\n"),
      "import std/db\necho value\n",
    ) == nil

    let workspace = initWorkspace()
    let fileId =
      workspace.openDocument("file:///incremental.nim", "incremental.nim", oldSource, 1)
    check workspace.changeDocument(
      "file:///incremental.nim", "incremental.nim", newSource, 2
    )
    check workspace.snapshotForFile(fileId).index.occurrences == rebuilt.occurrences

    let repeatedOld = "let value = 1\necho value\necho value\n"
    let repeatedNew = "let value = 1\necho other\necho value\n"
    let repeated =
      tryIndexSourceIncremental(repeatedOld, indexSource(repeatedOld), repeatedNew)
    check repeated != nil
    check repeated.occurrences == indexSource(repeatedNew).occurrences
    check tryIndexSourceIncremental(
      "include module\necho value\n",
      indexSource("include module\necho value\n"),
      "include changed\necho value\n",
    ) == nil
    check tryIndexSourceIncremental(
      "echo \"value\"\n", indexSource("echo \"value\"\n"), "echo \"other\"\n"
    ) == nil

  test "incremental successors keep predecessor indexes immutable":
    var source = "let value = 1\n"
    for _ in 0 ..< 130:
      source.add "echo value\n"
    let originalSource = source
    let originalIndex = indexSource(source)
    var current = originalIndex
    let edits =
      [(line: 1, name: "other"), (line: 64, name: "third"), (line: 127, name: "final")]
    for edit in edits:
      let previousSource = source
      let previousIndex = current
      source = replaceLine(source, edit.line, edit.name)
      current = tryIndexSourceIncremental(previousSource, previousIndex, source)
      if current == nil:
        raise
          newException(AssertionDefect, "incremental edit failed at line " & $edit.line)
      let rebuilt = indexSource(source)
      check current.parsed.tokens == rebuilt.parsed.tokens
      check current.symbols == rebuilt.symbols
      check current.scopes == rebuilt.scopes
      check current.occurrences == rebuilt.occurrences
      let previousRebuilt = indexSource(previousSource)
      check previousIndex.parsed.tokens == previousRebuilt.parsed.tokens
      check previousIndex.occurrences == previousRebuilt.occurrences

    let originalRebuilt = indexSource(originalSource)
    check originalIndex.parsed.tokens == originalRebuilt.parsed.tokens
    check originalIndex.occurrences == originalRebuilt.occurrences
