import std/[algorithm, strutils, unittest]
import std/os except FileId

import onim/features/definition
import onim/index/symbols
import onim/session/ids
import onim/session/workspace

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

proc resolveLast(
    workspace: Workspace, fileId: FileId, name: string
): DefinitionResolution =
  let snapshot = workspace.snapshotForFile(fileId)
  resolveDefinition(workspace, snapshot, snapshot.text.rfind(name))

proc providerSource(): string =
  """proc answer*() = discard
proc privateAnswer() = discard
proc overload*(value: int) = discard
proc overload*(value: string) = discard
proc forward*()
proc forward*() = discard
"""

suite "native definition resolution":
  test "resolves module qualifiers, aliases, and from bindings":
    let root = getTempDir() / ("onim-definition-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-definition-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, providerSource())
    writeFile(consumerPath, "import provider\nprovider.answer()\n")

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
    let providerId = workspace.fileIdForPath(providerPath)
    let consumerId = workspace.fileIdForPath(consumerPath)
    check providerId.valid
    check consumerId.valid

    var resolution = resolveLast(workspace, consumerId, "answer")
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value
    check workspace.indexViewForFile(providerId).index.symbols[
      int(resolution.target.nameToken)
    ].kind == symbolProc

    discard workspace.changeDocument(
      "file://" & consumerPath, consumerPath, "import provider as p\np.answer()\n", 2
    )
    resolution = resolveLast(workspace, consumerId, "answer")
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "from provider import answer\nanswer()\n",
      3,
    )
    resolution = resolveLast(workspace, consumerId, "answer")
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value

  test "returns conservative states for unsafe bindings":
    let root = getTempDir() / ("onim-definition-unsafe-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-definition-unsafe-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, providerSource())
    writeFile(consumerPath, "import provider\nprovider.privateAnswer()\n")

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
    let consumerId = workspace.fileIdForPath(consumerPath)

    check resolveLast(workspace, consumerId, "privateAnswer").kind == definitionUnknown

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "import provider\nprovider.overload()\n",
      2,
    )
    check resolveLast(workspace, consumerId, "overload").kind == definitionAmbiguous

    discard workspace.changeDocument(
      "file://" & consumerPath, consumerPath, "import provider\nprovider.forward()\n", 3
    )
    check resolveLast(workspace, consumerId, "forward").kind == definitionAmbiguous

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "when defined(posix):\n  import provider\nprovider.answer()\n",
      4,
    )
    check resolveLast(workspace, consumerId, "answer").kind == definitionUnknown

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "import provider except answer\nprovider.answer()\n",
      5,
    )
    check resolveLast(workspace, consumerId, "answer").kind == definitionUnknown

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "from provider import answer as local\nlocal()\n",
      6,
    )
    check resolveLast(workspace, consumerId, "local").kind == definitionUnknown

  test "uses published overlays and cache indexes without target hydration":
    let root = getTempDir() / ("onim-definition-overlay-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-definition-overlay-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let providerUri = "file:///overlay/provider.nim"
    writeFile(providerPath, "proc answer*() = discard\n")
    writeFile(consumerPath, "import provider\nprovider.answer()\n")

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
    let providerId = workspace.fileIdForPath(providerPath)
    let consumerId = workspace.fileIdForPath(consumerPath)
    let initial = resolveLast(workspace, consumerId, "answer")
    check initial.kind == definitionResolved
    check initial.target.fileId.value == providerId.value

    discard workspace.openDocument(
      providerUri, providerPath, "proc answer*() = discard\nproc extra*() = discard\n",
      1,
    )
    let overlay = resolveLast(workspace, consumerId, "answer")
    check overlay.kind == definitionResolved
    check overlay.target.contentGeneration.value !=
      initial.target.contentGeneration.value
    check workspace.indexViewForFile(providerId).uri == providerUri

    removeFile(providerPath)
    let published = resolveLast(workspace, consumerId, "answer")
    check published.kind == definitionResolved
    workspace.closeDocument(providerUri, providerPath)
    check resolveLast(workspace, consumerId, "answer").kind == definitionUnresolved
