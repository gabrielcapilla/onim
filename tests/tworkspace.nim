import std/[algorithm, strutils, unittest]
import std/os except FileId

import onim/index/cache
import onim/index/occurrences
import onim/index/scopes
import onim/index/scope_validation
import onim/index/source_index
import onim/index/surfaces
import onim/index/surface_resolution
import onim/session/ids
import onim/session/paths
import onim/session/workspace
import onim/session/workspace_models
import onim/index/type_kinds
import onim/index/type_queries
import onim/index/type_local_resolution
import onim/syntax/parser
import onim/index/types
import onim/syntax/tokens

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
  test "narrows document bootstrap to the nearest project root":
    let root = getTempDir() / ("onim-root-selection-" & $getCurrentProcessId())
    cleanTree(root)
    defer:
      cleanTree(root)
    let project = root / "project"
    let sourceRoot = project / "src"
    let mainPath = sourceRoot / "main.nim"
    let unrelatedPath = root / "unrelated" / "other.nim"
    createDir(sourceRoot)
    createDir(splitFile(unrelatedPath).dir)
    writeFile(project / "nim.cfg", "")
    writeFile(mainPath, "discard\n")
    writeFile(sourceRoot / "module.nim", "discard\n")
    writeFile(unrelatedPath, "discard\n")

    let workspace = initWorkspace()
    check broadWorkspaceRoot(getHomeDir())
    check broadWorkspaceRoot("/")
    check not broadWorkspaceRoot(root)
    check workspace.root.len == 0
    check workspace.prepareWorkspaceForDocument(mainPath)
    check workspace.root == canonicalPath(project)

    workspace.indexWorkspace()
    check workspace.fileIdForPath(mainPath).valid
    check not workspace.fileIdForPath(unrelatedPath).valid

  test "keeps an unmarked document local without recursive bootstrap":
    let root = getTempDir() / ("onim-root-selection-local-" & $getCurrentProcessId())
    cleanTree(root)
    defer:
      cleanTree(root)
    let path = root / "main.nim"
    createDir(root)
    writeFile(path, "discard\n")

    let workspace = initWorkspace()
    check not workspace.prepareWorkspaceForDocument(path)
    check workspace.root.len == 0
    check workspace.openDocument("file://" & path, path, "discard\n", 1).valid

  test "persists and reloads source indexes":
    let root = getTempDir() / ("onim-cache-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let filePath = root / "cached.nim"
    let source =
      "import std/os\nproc listFiles(dir: string) =\n  let widths: array[4, int] = default(array[4, int])\n  discard walkDir(dir)\n  discard widths\n"
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
    var widthsToken = InvalidTypeToken
    for declaration in secondSnapshot.index.scopes.declarations:
      let token = secondSnapshot.index.parsed.tokens[int(declaration.nameToken)]
      if secondSnapshot.index.parsed.tokens.tokenTextEquals(token, "widths"):
        widthsToken = declaration.nameToken
    check widthsToken != InvalidTypeToken
    let widths = secondSnapshot.index.types.localTypeAt(
      secondSnapshot.index.parsed.tokens, secondSnapshot.index.scopes, widthsToken
    )
    check widths.kind == typeArray
    check secondSnapshot.index.types.records[int(uint32(widths.typeId)) - 1].extent ==
      4'u32
    check secondSnapshot.index.nativeIndexSafe()

    let cacheBytes = readFile(path)
    writeFile(path, cacheBytes & "trailing")
    check loadCachedSourceIndex(root, filePath, source) == nil
    writeFile(path, "corrupt")
    check loadCachedSourceIndex(root, filePath, source) == nil

    let manifestBytes = readFile(manifestPath)
    writeFile(manifestPath, manifestBytes & "trailing")
    check loadProjectManifest(root).entries.len == 0

  test "persists recovered import boundaries":
    let root = getTempDir() / ("onim-recovery-cache-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-recovery-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let modulePath = root / "main.nim"
    let source = "import goodA\nimport pkg/[part,\nimport goodB\n"
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let index = indexSource(source)
    check index.syntax.importNodes.len == 3
    check index.imports == @["goodA", "goodB"]
    check saveCachedSourceIndex(root, modulePath, source, index)
    let loaded = loadCachedSourceIndex(root, modulePath, source)
    check loaded != nil
    check loaded.imports == index.imports
    check loaded.parsed.imports == index.parsed.imports
    check loaded.syntax.importNodes.len == index.syntax.importNodes.len
    check loaded.syntax.nodes[int(uint32(loaded.syntax.importNodes[1])) - 1].uncertainty ==
      index.syntax.nodes[int(uint32(index.syntax.importNodes[1])) - 1].uncertainty
    check loaded.syntax.importsMatch(loaded.parsed)

  test "indexes complete include statements without phantom dependencies":
    let root = getTempDir() / ("onim-include-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-include-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    createDir(root / "pkg")
    let mainPath = root / "main.nim"
    let source =
      "include\n" & "import goodA\n" &
      "include first, \"second\", \"included.nim\", pkg/[third, fourth]\n" &
      "include broken/[part,\n" & "include final\n"
    writeFile(mainPath, source)
    for path in [
      root / "goodA.nim",
      root / "first.nim",
      root / "second.nim",
      root / "included.nim",
      root / "final.nim",
      root / "import.nim",
      root / "broken.nim",
      root / "pkg" / "third.nim",
      root / "pkg" / "fourth.nim",
    ]:
      writeFile(path, "")

    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    let mainId = workspace.fileIdForPath(mainPath)
    let snapshot = workspace.snapshotForFile(mainId)
    check snapshot.index.syntax.importNodes.len == 1
    var certainIncludes = 0
    var uncertainIncludes = 0
    for node in snapshot.index.syntax.nodes:
      if node.kind != syntaxInclude:
        continue
      if node.uncertainty == {}:
        inc certainIncludes
      else:
        inc uncertainIncludes
    check certainIncludes == 2
    check uncertainIncludes == 2
    check workspace.graphComplete
    for path in [
      root / "goodA.nim",
      root / "first.nim",
      root / "second.nim",
      root / "included.nim",
      root / "final.nim",
      root / "pkg" / "third.nim",
      root / "pkg" / "fourth.nim",
    ]:
      check workspace.dependencies(mainId).hasId(workspace.fileIdForPath(path))
    check not workspace.dependencies(mainId).hasId(
      workspace.fileIdForPath(root / "import.nim")
    )
    check not workspace.dependencies(mainId).hasId(
      workspace.fileIdForPath(root / "broken.nim")
    )

    let warm = initWorkspace(root)
    warm.indexWorkspace()
    let warmMain = warm.fileIdForPath(mainPath)
    check warm.graphComplete
    let coldDependencies = workspace.dependencies(mainId)
    let warmDependencies = warm.dependencies(warmMain)
    check warmDependencies.len == coldDependencies.len
    for index in 0 ..< coldDependencies.len:
      check sameId(warmDependencies[index], coldDependencies[index])

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

  test "invalidates only the reverse dependency closure":
    let root = getTempDir() / ("onim-invalidation-" & $getCurrentProcessId())
    cleanRoot(root)
    createDir(root)
    defer:
      cleanRoot(root)

    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let downstreamPath = root / "downstream.nim"
    let unrelatedPath = root / "unrelated.nim"
    writeFile(providerPath, "proc provided*() = discard\n")
    writeFile(consumerPath, "import provider\nprovided()\n")
    writeFile(downstreamPath, "import consumer\n")
    writeFile(unrelatedPath, "proc idle*() = discard\n")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    let providerId = workspace.fileIdForPath(providerPath)
    let consumerId = workspace.fileIdForPath(consumerPath)
    let downstreamId = workspace.fileIdForPath(downstreamPath)
    let unrelatedId = workspace.fileIdForPath(unrelatedPath)
    check workspace.graphComplete
    discard workspace.drainInvalidated()
    let unrelatedGeneration =
      workspace.snapshotForFile(unrelatedId).dependencyGeneration

    writeFile(providerPath, "proc provided*() = echo 1\n")
    workspace.fileChanged(providerPath)
    let invalidated = workspace.drainInvalidated()
    check invalidated.hasId(providerId)
    check invalidated.hasId(consumerId)
    check invalidated.hasId(downstreamId)
    check not invalidated.hasId(unrelatedId)
    check workspace.snapshotForFile(unrelatedId).dependencyGeneration.value ==
      unrelatedGeneration.value

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
    let initialSurfaceGeneration = workspace.snapshotForFile(
      workspace.fileIdForPath(providerPath)
    ).surfaceGeneration.value

    workspace.configurationChanged()
    let configured = workspace.projectSurface()
    check configured != first
    check configured.lookupInModule("provider", "provided").kind == surfaceResolved
    let configuredSurfaceGeneration = workspace.snapshotForFile(
      workspace.fileIdForPath(providerPath)
    ).surfaceGeneration.value
    check configuredSurfaceGeneration != initialSurfaceGeneration

    writeFile(providerPath, "proc changed*() = discard\n")
    workspace.fileChanged(providerPath)
    let second = workspace.projectSurface()
    check second.lookupInModule("provider", "provided").kind == surfaceUnresolved
    check second.lookupInModule("provider", "changed").kind == surfaceResolved
    check workspace.snapshotForFile(workspace.fileIdForPath(providerPath)).surfaceGeneration.value !=
      configuredSurfaceGeneration

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

  test "indexes declared installed Nimble package sources":
    let root = getTempDir() / ("onim-installed-package-" & $getCurrentProcessId())
    let nimbleRoot = getTempDir() / ("onim-installed-nimble-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(nimbleRoot)
    createDir(root)
    createDir(nimbleRoot)
    createDir(nimbleRoot / "pkgs2")
    let packageRoot = nimbleRoot / "pkgs2" / "sample-2.0.0"
    createDir(packageRoot)
    createDir(packageRoot / "src")
    let mainPath = root / "main.nim"
    let packagePath = packageRoot / "src" / "sample.nim"
    writeFile(
      root / "app.nimble", "requires \"nim >= 2.2.0\"\nrequires \"sample >= 1.0\"\n"
    )
    writeFile(packageRoot / "sample.nimble", "version = \"2.0.0\"\nsrcDir = \"src\"\n")
    writeFile(mainPath, "import sample\ndiscard answer()\n")
    writeFile(packagePath, "proc answer*(): int = 42\n")

    let previousNimbleRoot = getEnv("NIMBLE_DIR")
    putEnv("NIMBLE_DIR", nimbleRoot)
    defer:
      if previousNimbleRoot.len > 0:
        putEnv("NIMBLE_DIR", previousNimbleRoot)
      else:
        delEnv("NIMBLE_DIR")
      cleanTree(root)
      cleanTree(nimbleRoot)

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    let mainId = workspace.fileIdForPath(mainPath)
    let packageId = workspace.fileIdForPath(packagePath)
    check mainId.valid
    check packageId.valid
    check workspace.fileCount == 2
    check workspace.moduleForPath(packagePath) == "sample"
    check workspace.dependencies(mainId).hasId(packageId)
    check workspace.graphComplete
    check workspace.manifest.entries.len == 1
    check workspace.manifest.entries[0].path == absolutePath(mainPath)
    let surface = workspace.projectSurface()
    let answer = surface.lookupInModule("sample", "answer")
    check answer.kind == surfaceResolved
    check surface.moduleAt(answer.candidates[0].surface).origin == surfaceExternal

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
    let localThingPath = root / "localThing.nim"
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
    writeFile(
      exporterPath,
      "import c\nfrom c import c\nimport c as moduleAlias\n" &
        "proc localThing() = discard\nexport c\nexport moduleAlias\n" &
        "export c\nexport localThing\n",
    )
    writeFile(localThingPath, "proc decoy() = discard\n")
    writeFile(includeParentPath, "include included\n")
    writeFile(includedPath, "const includedValue = 1\n")
    writeFile(cycleOnePath, "import cycle2\n")
    writeFile(cycleTwoPath, "import cycle1\n")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.fileCount == 11
    check workspace.graphComplete
    check workspace.drainInvalidated().len == 0

    let aId = workspace.fileIdForPath(aPath)
    let bId = workspace.fileIdForPath(bPath)
    let cId = workspace.fileIdForPath(cPath)
    let dId = workspace.fileIdForPath(dPath)
    let eId = workspace.fileIdForPath(ePath)
    let exporterId = workspace.fileIdForPath(exporterPath)
    let localThingId = workspace.fileIdForPath(localThingPath)
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
    check not workspace.dependencies(exporterId).hasId(localThingId)
    check workspace.dependents(localThingId).len == 0
    check workspace.dependencies(includeParentId).len == 1
    check workspace.dependencies(includeParentId).hasId(includedId)

    let cachedBefore = workspace.snapshotForFile(cId)
    workspace.indexWorkspace()
    let cachedAfter = workspace.snapshotForFile(cId)
    check cachedBefore.contentGeneration.value == cachedAfter.contentGeneration.value
    check cachedBefore.dependencyGeneration.value ==
      cachedAfter.dependencyGeneration.value
    check cachedBefore.index == cachedAfter.index

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

    writeFile(localThingPath, "proc changedDecoy() = discard\n")
    workspace.fileChanged(localThingPath)
    let decoyChanged = workspace.drainInvalidated()
    check decoyChanged.hasId(localThingId)
    check not decoyChanged.hasId(exporterId)

    let unrelatedBefore = workspace.snapshotForFile(cId)
    check workspace.changeDocument(
      uriFor(aPath), aPath, "import b\nimport c\n# unrelated edit\n", 0
    )
    discard workspace.drainInvalidated()
    let unrelatedAfter = workspace.snapshotForFile(cId)
    check unrelatedBefore.fileId.sameId(unrelatedAfter.fileId)
    check unrelatedBefore.contentGeneration.value ==
      unrelatedAfter.contentGeneration.value
    check unrelatedBefore.dependencyGeneration.value ==
      unrelatedAfter.dependencyGeneration.value
    check unrelatedBefore.index == unrelatedAfter.index

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
    check conservative.len == 1
    check conservative.sortedUnique
    check conservative.hasId(aId)
    check not conservative.hasId(unresolvedId)

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
