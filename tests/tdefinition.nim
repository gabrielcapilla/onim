import std/[algorithm, strutils, unittest]
import std/os except FileId

import onim/features/definition
import onim/index/symbols
import onim/index/types
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
  """proc answer() = discard
export answer
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

  test "resolves exact same-file UFCS members":
    let text = """proc scaled(value: int) = discard
proc rendered(value: string) = discard
proc show(value: int) =
  discard value.scaled
proc showText(value: string) =
  discard value.scaled
"""
    let workspace = initWorkspace()
    let fileId = workspace.openDocument(
      "file:///tmp/onim-local-ufcs.nim", "/tmp/onim-local-ufcs.nim", text, 1
    )
    let snapshot = workspace.snapshotForFile(fileId)
    let matched = resolveDefinition(
      workspace, snapshot, text.find("value.scaled") + "value.".len + 1
    )
    check matched.kind == definitionResolved
    check matched.target.fileId.value == fileId.value
    check snapshot.index.parsed.tokens.tokenText(
      snapshot.index.parsed.tokens[int(matched.target.nameToken)]
    ) == "scaled"
    let mismatch = resolveDefinition(
      workspace, snapshot, text.rfind("value.scaled") + "value.".len + 1
    )
    check mismatch.kind == definitionUnsupported

    let fieldText = """type Item = object
  size*: int
proc size(value: Item) = discard
proc use(item: Item) =
  discard item.size
"""
    let fieldWorkspace = initWorkspace()
    let fieldId = fieldWorkspace.openDocument(
      "file:///tmp/onim-ufcs-field.nim", "/tmp/onim-ufcs-field.nim", fieldText, 1
    )
    let fieldSnapshot = fieldWorkspace.snapshotForFile(fieldId)
    let fieldResolution = resolveDefinition(
      fieldWorkspace, fieldSnapshot, fieldText.rfind("item.size") + "item.".len + 1
    )
    check fieldResolution.kind == definitionResolved
    check fieldResolution.target.kind == targetObjectField

  test "resolves exported UFCS members from direct project imports":
    let root = getTempDir() / ("onim-ufcs-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-ufcs-project-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(
      providerPath,
      "proc scale*(value: int; amount: int) = discard\n" &
        "proc scale*(value: int; amount: int; label: string) = discard\n" &
        "proc makeValues*(): seq[int] = nil\n" &
        "proc total*(values: seq[int]) = discard\n",
    )
    writeFile(
      consumerPath,
      "import provider\nproc use(value: int) =\n  discard value.scale(1)\n",
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
    check workspace.graphComplete
    let snapshot = workspace.snapshotForFile(consumerId)
    let memberOffset = snapshot.text.rfind("value.scale") + "value.".len + 1
    var resolution = resolveDefinition(workspace, snapshot, memberOffset)
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value
    let providerSnapshot = workspace.snapshotForFile(providerId)
    check providerSnapshot.index.parsed.tokens[int(resolution.target.nameToken)].startOffset ==
      providerSnapshot.text.find("proc scale") + "proc ".len
    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "import provider\nproc use(value: int) =\n  discard value.scale(1)\n" &
        "  let values = provider.makeValues()\n" & "  discard values.total()\n",
      2,
    )
    let valuesSnapshot = workspace.snapshotForFile(consumerId)
    var valuesToken = InvalidTypeToken
    for declaration in valuesSnapshot.index.scopes.declarations:
      if valuesSnapshot.index.parsed.tokens.tokenTextEquals(
        valuesSnapshot.index.parsed.tokens[int(declaration.nameToken)], "values"
      ):
        valuesToken = declaration.nameToken
    check valuesToken != InvalidTypeToken
    let valuesType = workspace.resolveLocalType(valuesSnapshot, valuesToken)
    check valuesType.info.state == typeStateResolved
    check valuesType.info.kind == typeSeq
    let valuesOffset = valuesSnapshot.text.rfind("values.total") + "values.".len + 1
    let valuesResolution = resolveDefinition(workspace, valuesSnapshot, valuesOffset)
    check valuesResolution.kind == definitionResolved
    check valuesResolution.target.fileId.value == providerId.value

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "from provider import scale\nproc use(value: int) =\n  discard value.scale(1, \"label\")\n",
      2,
    )
    resolution = resolveLast(workspace, consumerId, "scale")
    check resolution.kind == definitionResolved

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "import provider except scale\nproc use(value: int) =\n  discard value.scale(1)\n",
      3,
    )
    check resolveLast(workspace, consumerId, "scale").kind == definitionUnsupported

  test "selects exact UFCS overloads by complete call arity":
    let text = """proc choose(value: int; amount: int) = discard
proc choose(value: int; amount: int; label: string) = discard
proc same(value: int; amount: int) = discard
proc same(value: int; amount: string) = discard
proc optional(value: int; amount: int = 1) = discard
proc variable(value: int; rest: varargs[string]) = discard
proc use(value: int) =
  discard value.choose(1)
proc useMany(value: int) =
  discard value.choose(1, "label")
proc useNested(value: int) =
  discard value.choose(pair(1, 2))
proc useSame(value: int) =
  discard value.same(1)
proc useBare(value: int) =
  discard value.same
proc useOptional(value: int) =
  discard value.optional()
proc useVariable(value: int) =
  discard value.variable()
"""
    let workspace = initWorkspace()
    let fileId = workspace.openDocument(
      "file:///tmp/onim-ufcs-arity.nim", "/tmp/onim-ufcs-arity.nim", text, 1
    )
    let snapshot = workspace.snapshotForFile(fileId)
    let firstChoose = text.find("proc choose") + "proc ".len
    let secondChoose = text.find("proc choose", firstChoose + 1) + "proc ".len

    var resolution = resolveDefinition(
      workspace, snapshot, text.find("value.choose(1)") + "value.".len + 1
    )
    check resolution.kind == definitionResolved
    check snapshot.index.parsed.tokens[int(resolution.target.nameToken)].startOffset ==
      firstChoose

    resolution = resolveDefinition(
      workspace, snapshot, text.find("value.choose(1, \"label\")") + "value.".len + 1
    )
    check resolution.kind == definitionResolved
    check snapshot.index.parsed.tokens[int(resolution.target.nameToken)].startOffset ==
      secondChoose

    resolution = resolveDefinition(
      workspace, snapshot, text.find("value.choose(pair") + "value.".len + 1
    )
    check resolution.kind == definitionResolved
    check snapshot.index.parsed.tokens[int(resolution.target.nameToken)].startOffset ==
      firstChoose
    check resolveLast(workspace, fileId, "same").kind == definitionAmbiguous
    check resolveLast(workspace, fileId, "optional").kind == definitionUnsupported
    check resolveLast(workspace, fileId, "variable").kind == definitionUnsupported

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
    check localTargetSnapshot.index.parsed.tokens.tokenText(
      localTargetSnapshot.index.parsed.tokens[int(localResolution.target.nameToken)]
    ) == "display_name"

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
proc show(person: ref model.Person) =
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
    check providerSnapshot.index.parsed.tokens.tokenText(
      providerSnapshot.index.parsed.tokens[int(resolution.target.nameToken)]
    ) == "display_name"

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

    let genericText = """type Box[T] = object
  value: T

proc makeBox(): Box[int] =
  Box[int](value: 1)

proc use() =
  let box = makeBox()
  discard box.value
"""
    let genericWorkspace = initWorkspace()
    let genericId = genericWorkspace.openDocument(
      "file:///tmp/onim-generic-field.nim", "/tmp/onim-generic-field.nim", genericText,
      1,
    )
    let genericResolution = resolveLast(genericWorkspace, genericId, "value")
    check genericResolution.kind == definitionResolved
    check genericResolution.target.kind == targetObjectField

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
    proc typeStateFor(
        workspace: Workspace, snapshot: WorkspaceSnapshot, name: string
    ): TypeState =
      for declaration in snapshot.index.scopes.declarations:
        let token = snapshot.index.parsed.tokens[int(declaration.nameToken)]
        if snapshot.index.parsed.tokens.tokenTextEquals(token, name):
          return workspace.resolveLocalType(snapshot, declaration.nameToken).info.state
      typeStateUnknown

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
    proc typeStateFor(name: string): TypeState =
      for declaration in snapshot.index.scopes.declarations:
        let token = snapshot.index.parsed.tokens[int(declaration.nameToken)]
        if snapshot.index.parsed.tokens.tokenTextEquals(token, name):
          return workspace.resolveLocalType(snapshot, declaration.nameToken).info.state
      typeStateUnknown

    check typeStateFor("built") == typeStateGenerated
    check typeStateFor("templated") == typeStateGenerated
    check typeStateFor("known") == typeStateUnknown
    check typeStateFor("local") == typeStateResolved

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
