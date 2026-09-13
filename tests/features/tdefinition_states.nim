import std/[strutils, unittest]
import std/os except FileId

import onim/features/definition
import onim/features/definition_models
import onim/features/implementation
import onim/index/symbols
import onim/index/type_kinds
import onim/index/type_queries
import onim/index/type_states
import onim/session/ids
import onim/session/workspace
import onim/session/workspace_models
import onim/syntax/tokens
import harness/workspace_fs
import features/definition_support

suite "native definition resolution":
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
    let providerId = workspace.fileIdForPath(providerPath)
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
    let localResolution = resolveLast(workspace, consumerId, "local")
    check localResolution.kind == definitionResolved
    check localResolution.target.fileId.value == providerId.value

  test "resolves module routines inside conditional blocks":
    let text = "proc main() = discard\nwhen isMainModule:\n  main()\n"
    let workspace = initWorkspace()
    let fileId = workspace.openDocument(
      "file:///tmp/onim-conditional-main.nim", "/tmp/onim-conditional-main.nim", text, 1
    )
    let snapshot = workspace.snapshotForFile(fileId)
    let resolution = resolveDefinition(workspace, snapshot, text.rfind("main"))
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == fileId.value
    check resolution.target.nameToken < uint32(snapshot.index.parsed.tokens.len)
    check snapshot.index.parsed.tokens.tokenText(
      snapshot.index.parsed.tokens[int(resolution.target.nameToken)]
    ) == "main"

  test "resolves exported routines from relative plain imports":
    let root = getTempDir() / ("onim-definition-plain-import-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-definition-plain-import-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "proc provided*() = discard\n")
    writeFile(consumerPath, "import ./provider\nprovided()\n")

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
    let resolution = resolveLast(workspace, consumerId, "provided")
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value

  test "selects fixed-arity definitions for direct calls":
    let text = """proc overload(value: int) = discard
proc overload(value: string; radix: int) = discard

proc show() =
  overload(1)
  overload("text", 10)
"""
    let workspace = initWorkspace()
    let fileId = workspace.openDocument(
      "file:///tmp/onim-local-overloads.nim", "/tmp/onim-local-overloads.nim", text, 1
    )
    let snapshot = workspace.snapshotForFile(fileId)
    let integerCall = resolveDefinition(workspace, snapshot, text.find("overload(1"))
    check integerCall.kind == definitionResolved
    if integerCall.kind == definitionResolved:
      check snapshot.index.parsed.tokens[int(integerCall.target.nameToken)].line == 0
    let stringCall =
      resolveDefinition(workspace, snapshot, text.find("overload(\"text\", 10"))
    check stringCall.kind == definitionResolved
    if stringCall.kind == definitionResolved:
      check snapshot.index.parsed.tokens[int(stringCall.target.nameToken)].line == 1

  test "selects fixed-arity definitions for qualified project calls":
    let root = getTempDir() / ("onim-qualified-overloads-" & $getCurrentProcessId())
    cleanTree(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(
      providerPath,
      """proc overload*(value: int) = discard
proc overload*(value: int; label: string) = discard
""",
    )
    writeFile(consumerPath, "import provider\nprovider.overload(1)\n")
    defer:
      cleanTree(root)

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    let consumerId = workspace.fileIdForPath(consumerPath)
    var resolution = resolveLast(workspace, consumerId, "overload")
    check resolution.kind == definitionResolved
    if resolution.kind == definitionResolved:
      let provider = workspace.snapshotForFile(workspace.fileIdForPath(providerPath))
      check provider.index.parsed.tokens[int(resolution.target.nameToken)].line == 0

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "import provider\nprovider.overload(1, \"text\")\n",
      2,
    )
    resolution = resolveLast(workspace, consumerId, "overload")
    check resolution.kind == definitionResolved
    if resolution.kind == definitionResolved:
      let provider = workspace.snapshotForFile(workspace.fileIdForPath(providerPath))
      check provider.index.parsed.tokens[int(resolution.target.nameToken)].line == 1

  test "labels resolved, unresolved, and ambiguous local call types":
    let text = """proc answer(): int = 1
proc overload(value: int) = discard
proc overload(value: string) = discard

proc show() =
  let known = answer()
  let missing = absent()
  let ambiguous = overload()
  discard known
  discard missing
  discard ambiguous
"""
    let workspace = initWorkspace()
    let fileId = workspace.openDocument(
      "file:///tmp/onim-local-type-state.nim", "/tmp/onim-local-type-state.nim", text, 1
    )
    let snapshot = workspace.snapshotForFile(fileId)
    check typeStateFor(workspace, snapshot, "known") == typeStateResolved
    check typeStateFor(workspace, snapshot, "missing") == typeStateUnknown
    check typeStateFor(workspace, snapshot, "ambiguous") == typeStateAmbiguous

  test "classifies imported macro and template calls as generated":
    let root = getTempDir() / ("onim-generated-type-state-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-generated-type-state-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(
      providerPath,
      """macro build*(value: untyped): untyped = value
template choose*(value: untyped): untyped = value
proc answer*(): int = 1
""",
    )
    writeFile(
      consumerPath,
      """import provider
proc localAnswer(): int = 1
proc use() =
  let built = provider.build(1)
  let templated = provider.choose(1)
  let known = provider.answer()
  let local = localAnswer()
  discard built
  discard templated
  discard known
  discard local
""",
    )
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
    let snapshot = workspace.snapshotForFile(consumerId)
    check typeStateFor(workspace, snapshot, "built") == typeStateGenerated
    check typeStateFor(workspace, snapshot, "templated") == typeStateGenerated
    check typeStateFor(workspace, snapshot, "known") == typeStateUnknown
    check typeStateFor(workspace, snapshot, "local") == typeStateResolved

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
