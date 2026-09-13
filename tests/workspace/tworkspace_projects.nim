import std/[strutils, unittest]
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
import onim/syntax/tokens
import harness/workspace_fs
import workspace/workspace_support

suite "workspace index":
  test "resolves conventional and Nimble import roots":
    let root = getTempDir() / ("onim-import-roots-" & $getCurrentProcessId())
    cleanTree(root)
    createDir(root)
    createDir(root / "src")
    createDir(root / "lib")
    defer:
      cleanTree(root)

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
    cleanTree(root)
    createDir(root)
    defer:
      cleanTree(root)

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
    cleanTree(root)
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
      cleanTree(root)
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
