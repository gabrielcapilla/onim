import std/[atomics, os, unittest]

import onim/index/cache
import onim/session/bootstrap_worker
import onim/session/ids
import onim/session/workspace
import harness/workspace_fs

var bootstrapBridgeStopped: Atomic[bool]

proc consumeBootstrapUntilStopped() {.thread, gcsafe.} =
  while true:
    if receiveBootstrap().kind == bootstrapStopped:
      bootstrapBridgeStopped.store(true, moRelaxed)
      break

suite "background workspace bootstrap":
  test "builds and publishes a path-indexed project result":
    let root = getTempDir() / ("onim-background-bootstrap-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-background-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    writeFile(root / "provider.nim", "proc answer*() = discard\n")
    writeFile(root / "consumer.nim", "import provider\nprovider.answer()\n")
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      stopBootstrapWorker()
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let workspace = initWorkspace()
    check workspace.prepareWorkspace(root)
    check startBootstrapWorker()
    let request = BootstrapRequest(
      jobGeneration: 1,
      workspaceGeneration: workspace.workspaceGeneration(),
      configGeneration: workspace.configurationGeneration(),
      root: workspace.root,
    )
    check submitBootstrap(request)
    let value = receiveBootstrap()
    check value.kind == bootstrapComplete
    check value.files.len == 2
    check value.discoveryValid
    check value.directories.len > 0
    let roundTrip = decodeBootstrapResult(encodeBootstrapResult(value))
    check roundTrip.kind == bootstrapComplete
    check roundTrip.discoveryValid
    check roundTrip.directories == value.directories
    removeFile(cacheFilePath(root, root / "provider.nim"))
    check workspace.applyBootstrap(value)
    let provider = workspace.fileIdForPath(root / "provider.nim")
    let consumer = workspace.fileIdForPath(root / "consumer.nim")
    check value(provider) != 0'u32
    check value(consumer) != 0'u32
    let providerView = workspace.indexViewForFile(provider)
    check providerView.valid
    check providerView.index != nil
    check workspace.dependencies(consumer).len == 1
    check workspace.dependencies(consumer)[0].value == provider.value
    check workspace.graphComplete
    let before = workspace.snapshotForFile(provider)
    check workspace.applyBootstrap(value)
    let after = workspace.snapshotForFile(provider)
    check before.contentGeneration.value == after.contentGeneration.value
    check before.dependencyGeneration.value == after.dependencyGeneration.value
    check before.index == after.index

  test "rejects a stale result without mutating the workspace":
    let root = getTempDir() / ("onim-background-stale-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-background-stale-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let filePath = root / "main.nim"
    writeFile(filePath, "echo 1\n")
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      stopBootstrapWorker()
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let workspace = initWorkspace()
    check workspace.prepareWorkspace(root)
    check startBootstrapWorker()
    check submitBootstrap(
      BootstrapRequest(
        jobGeneration: 2,
        workspaceGeneration: workspace.workspaceGeneration(),
        configGeneration: workspace.configurationGeneration(),
        root: workspace.root,
      )
    )
    let value = receiveBootstrap()
    check value.kind == bootstrapComplete
    discard workspace.openDocument("file://" & filePath, filePath, "echo 2\n", 1)
    check not workspace.applyBootstrap(value)
    check value(workspace.fileIdForPath(filePath)) != 0'u32
    check workspace.snapshotForFile(workspace.fileIdForPath(filePath)).text == "echo 2\n"

  test "joins the result bridge before closing channels":
    check startBootstrapWorker()
    defer:
      stopBootstrapWorker()
    bootstrapBridgeStopped.store(false, moRelaxed)
    var bridge: Thread[void]
    createThread(bridge, consumeBootstrapUntilStopped)
    stopBootstrapProducer()
    bridge.joinThread()
    check bootstrapBridgeStopped.load(moRelaxed)
    finishBootstrapWorkerStop()
    check startBootstrapWorker()
    stopBootstrapWorker()
