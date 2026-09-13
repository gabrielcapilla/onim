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
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
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
    cleanTree(root)
    createDir(root)
    defer:
      cleanTree(root)

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
    cleanTree(root)
    createDir(root)
    defer:
      cleanTree(root)

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

    let rebuilt = initWorkspace(root)
    rebuilt.indexWorkspace()
    let rebuiltSurface = rebuilt.projectSurface()
    check rebuiltSurface.valid
    check rebuiltSurface.moduleCount == second.moduleCount
    check rebuiltSurface.bindingCount == second.bindingCount
    check rebuiltSurface.exportCount == second.exportCount
    check rebuiltSurface.lookupInModule("provider", "provided").kind ==
      second.lookupInModule("provider", "provided").kind
    check rebuiltSurface.lookupInModule("provider", "changed").kind ==
      second.lookupInModule("provider", "changed").kind
    let rebuiltConsumer = rebuilt.fileIdForPath(consumerPath)
    check rebuilt.dependencies(rebuiltConsumer).len ==
      workspace.dependencies(workspace.fileIdForPath(consumerPath)).len
