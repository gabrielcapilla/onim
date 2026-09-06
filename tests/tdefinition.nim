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
  test "resolves routine parameters and direct locals":
    let text = """proc add(value: int) =
  let total = value + 1
  echo total
"""
    let workspace = initWorkspace()
    let fileId = workspace.openDocument(
      "file:///tmp/onim-local-definition.nim", "/tmp/onim-local-definition.nim", text, 1
    )
    let snapshot = workspace.snapshotForFile(fileId)
    let parameter = resolveDefinition(workspace, snapshot, text.rfind("value"))
    check parameter.kind == definitionResolved
    check parameter.target.fileId.value == fileId.value
    check parameter.target.nameToken == 3'u32

    let local = resolveDefinition(workspace, snapshot, text.rfind("total"))
    check local.kind == definitionResolved
    check local.target.fileId.value == fileId.value
    check local.target.nameToken == 9'u32

  test "resolves object fields through local and project receivers":
    let localText = """type Person = object
  display_name*: string

proc show(person: Person) =
  discard person.displayName
"""
    let localWorkspace = initWorkspace()
    let localId = localWorkspace.openDocument(
      "file:///tmp/onim-local-field.nim", "/tmp/onim-local-field.nim", localText, 1
    )
    let localResolution = resolveLast(localWorkspace, localId, "displayName")
    check localResolution.kind == definitionResolved
    check localResolution.target.kind == targetObjectField
    check localResolution.target.fileId.value == localId.value
    let localTargetSnapshot = localWorkspace.snapshotForFile(localId)
    check localTargetSnapshot.index.parsed.tokens[int(localResolution.target.nameToken)].text ==
      "display_name"

    let root =
      getTempDir() / ("onim-field-definition-project-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-field-definition-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(
      providerPath,
      """type Person* = object
  display_name*: string
  privateName: string
""",
    )
    writeFile(
      consumerPath,
      """import provider as model
proc show(person: model.Person) =
  discard person.displayName
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
    let providerId = workspace.fileIdForPath(providerPath)
    let consumerId = workspace.fileIdForPath(consumerPath)
    var resolution = resolveLast(workspace, consumerId, "displayName")
    check resolution.kind == definitionResolved
    check resolution.target.kind == targetObjectField
    check resolution.target.fileId.value == providerId.value
    let providerSnapshot = workspace.snapshotForFile(providerId)
    check providerSnapshot.index.parsed.tokens[int(resolution.target.nameToken)].text ==
      "display_name"

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "import provider as model\nproc show(person: model.Person) =\n  discard person.privateName\n",
      2,
    )
    resolution = resolveLast(workspace, consumerId, "privateName")
    check resolution.kind == definitionUnsupported

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "import provider as model\nproc show() =\n  let person = model.Person()\n  discard person.displayName\n",
      3,
    )
    resolution = resolveLast(workspace, consumerId, "displayName")
    check resolution.kind == definitionResolved
    check resolution.target.kind == targetObjectField

    let reopened = initWorkspace(root)
    reopened.indexWorkspace()
    let reopenedConsumer = reopened.fileIdForPath(consumerPath)
    resolution = resolveLast(reopened, reopenedConsumer, "displayName")
    check resolution.kind == definitionResolved
    check resolution.target.kind == targetObjectField

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
