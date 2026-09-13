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
  test "resolves exported enum members from direct project imports":
    let root = getTempDir() / ("onim-enum-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-enum-project-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "colors.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "type Color* = enum\n  red, green, blue\n")
    writeFile(consumerPath, "import colors\nproc show() =\n  discard Color.green\n")

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
    let resolution = resolveDefinition(
      workspace, snapshot, snapshot.text.find("Color.green") + "Color.".len + 1
    )
    check resolution.kind == definitionResolved
    check resolution.target.kind == targetObjectField
    check resolution.target.fileId.value == providerId.value
    let providerSnapshot = workspace.snapshotForFile(providerId)
    check providerSnapshot.index.parsed.tokens.tokenText(
      providerSnapshot.index.parsed.tokens[int(resolution.target.nameToken)]
    ) == "green"
    let fromConsumer =
      "from colors import Color\nproc show() =\n  discard Color.green\n"
    discard
      workspace.changeDocument("file://" & consumerPath, consumerPath, fromConsumer, 2)
    let fromSnapshot = workspace.snapshotForFile(consumerId)
    let fromResolution = resolveDefinition(
      workspace, fromSnapshot, fromSnapshot.text.find("Color.green") + "Color.".len + 1
    )
    check fromResolution.kind == definitionResolved
    check fromResolution.target.kind == targetObjectField
    check fromResolution.target.fileId.value == providerId.value

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

  test "resolves a project unary generic UFCS target":
    let root = getTempDir() / ("onim-generic-ufcs-definition-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-generic-ufcs-definition-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(
      providerPath,
      """type Box*[T] = object
  value: T

proc first*(box: Box[int]): int = discard

type Pair*[A, B] = object
  left: A
  right: B

proc pairFirst*(pair: Pair[int, string]): int = discard
proc pairBool*(pair: Pair[int, bool]): int = discard
""",
    )
    let consumer = """import provider
proc show(value: provider.Box[int]) =
  discard value.first()
proc showPair(value: provider.Pair[int, string]) =
  discard value.pairFirst()
proc showPairMismatch(value: provider.Pair[int, bool]) =
  discard value.pairFirst()
"""
    writeFile(consumerPath, consumer)

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
    let resolution = resolveDefinition(
      workspace, snapshot, snapshot.text.find("value.first") + "value.".len + 1
    )
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value
    let providerSnapshot = workspace.snapshotForFile(providerId)
    check providerSnapshot.index.parsed.tokens.tokenText(
      providerSnapshot.index.parsed.tokens[int(resolution.target.nameToken)]
    ) == "first"
    let pairOffset = snapshot.text.find("value.pairFirst") + "value.".len + 1
    let pairResolution = resolveDefinition(workspace, snapshot, pairOffset)
    check pairResolution.kind == definitionResolved
    check pairResolution.target.fileId.value == providerId.value
    check providerSnapshot.index.parsed.tokens.tokenText(
      providerSnapshot.index.parsed.tokens[int(pairResolution.target.nameToken)]
    ) == "pairFirst"
    let mismatchOffset =
      snapshot.text.find("value.pairFirst", snapshot.text.find("showPairMismatch")) +
      "value.".len + 1
    check resolveDefinition(workspace, snapshot, mismatchOffset).kind ==
      definitionUnsupported

  test "selects exact UFCS overloads by complete call arity":
    let text = """proc choose(value: int; amount: int) = discard
proc choose(value: int; amount: int; label: string) = discard
proc same(value: int; amount: int) = discard
proc same(value: int; amount: string) = discard
proc optional(value: int; amount: int = 1) = discard
proc optional(value: int; amount: string) = discard
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
    let optionalDeclaration = text.find("proc optional") + "proc ".len

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
    let optionalResolution = resolveLast(workspace, fileId, "optional")
    check optionalResolution.kind == definitionResolved
    check snapshot.index.parsed.tokens[int(optionalResolution.target.nameToken)].startOffset ==
      optionalDeclaration
    check resolveLast(workspace, fileId, "variable").kind == definitionUnsupported

  test "keeps malformed optional arity conservative":
    let malformedDefault = """proc optional(value: int; amount: int =) = discard
proc use(value: int) =
  discard value.optional()
"""
    let defaultWorkspace = initWorkspace()
    let defaultFile = defaultWorkspace.openDocument(
      "file:///tmp/onim-ufcs-malformed-default.nim",
      "/tmp/onim-ufcs-malformed-default.nim", malformedDefault, 1,
    )
    let defaultSnapshot = defaultWorkspace.snapshotForFile(defaultFile)
    let defaultOffset = malformedDefault.find("value.optional") + "value.".len + 1
    check resolveDefinition(defaultWorkspace, defaultSnapshot, defaultOffset).kind ==
      definitionUnsupported

    let malformedCall = """proc optional(value: int; amount: int = 1) = discard
proc use(value: int) =
  discard value.optional(amount = )
"""
    let callWorkspace = initWorkspace()
    let callFile = callWorkspace.openDocument(
      "file:///tmp/onim-ufcs-malformed-call.nim", "/tmp/onim-ufcs-malformed-call.nim",
      malformedCall, 1,
    )
    let callSnapshot = callWorkspace.snapshotForFile(callFile)
    let callOffset = malformedCall.find("value.optional") + "value.".len + 1
    check resolveDefinition(callWorkspace, callSnapshot, callOffset).kind !=
      definitionResolved

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

    let tupleText = """type Point = tuple[x: int, label: string]
proc show(point: Point) =
  discard point.label
"""
    let tupleWorkspace = initWorkspace()
    let tupleId = tupleWorkspace.openDocument(
      "file:///tmp/onim-tuple-field.nim", "/tmp/onim-tuple-field.nim", tupleText, 1
    )
    let tupleResolution = resolveLast(tupleWorkspace, tupleId, "label")
    check tupleResolution.kind == definitionResolved
    check tupleResolution.target.kind == targetObjectField
    let tupleSnapshot = tupleWorkspace.snapshotForFile(tupleId)
    check tupleSnapshot.index.parsed.tokens.tokenText(
      tupleSnapshot.index.parsed.tokens[int(tupleResolution.target.nameToken)]
    ) == "label"

    let inferredTupleText = """proc show() =
  let point = (x: 1, y: "ok")
  discard point.x
"""
    let inferredTupleWorkspace = initWorkspace()
    let inferredTupleId = inferredTupleWorkspace.openDocument(
      "file:///tmp/onim-inferred-tuple-field.nim", "/tmp/onim-inferred-tuple-field.nim",
      inferredTupleText, 1,
    )
    let inferredTupleResolution =
      resolveLast(inferredTupleWorkspace, inferredTupleId, "x")
    check inferredTupleResolution.kind == definitionResolved
    check inferredTupleResolution.target.kind == targetObjectField
    let inferredTupleSnapshot = inferredTupleWorkspace.snapshotForFile(inferredTupleId)
    check inferredTupleSnapshot.index.parsed.tokens.tokenText(
      inferredTupleSnapshot.index.parsed.tokens[
        int(inferredTupleResolution.target.nameToken)
      ]
    ) == "x"
    let unnamedWorkspace = initWorkspace()
    let unnamedId = unnamedWorkspace.openDocument(
      "file:///tmp/onim-unnamed-tuple-field.nim", "/tmp/onim-unnamed-tuple-field.nim",
      "proc show() =\n  let unnamed = (1, \"ok\")\n  discard unnamed.x\n", 1,
    )
    check resolveLast(unnamedWorkspace, unnamedId, "x").kind == definitionUnsupported

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
      "from provider import answer as execute\nexecute()\n",
      4,
    )
    resolution = resolveLast(workspace, consumerId, "execute")
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value

    discard workspace.changeDocument(
      "file://" & consumerPath,
      consumerPath,
      "from provider import answer\nanswer()\n",
      5,
    )
    resolution = resolveLast(workspace, consumerId, "answer")
    check resolution.kind == definitionResolved
    check resolution.target.fileId.value == providerId.value
