import std/[os, strutils, unittest]

import onim/session/bootstrap_worker
import onim/session/ids
import onim/session/workspace

proc cleanTree(path: string) =
  if not dirExists(path):
    return
  for entry in walkDirRec(path):
    if fileExists(entry):
      removeFile(entry)
  removeDir(path)

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
    check workspace.applyBootstrap(value)
    let provider = workspace.fileIdForPath(root / "provider.nim")
    let consumer = workspace.fileIdForPath(root / "consumer.nim")
    check value(provider) != 0'u32
    check value(consumer) != 0'u32
    check workspace.dependencies(consumer).len == 1
    check workspace.dependencies(consumer)[0].value == provider.value
    check workspace.graphComplete

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
