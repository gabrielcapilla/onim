import std/[algorithm, strutils, unittest]
import std/os except FileId

import onim/features/definition
import onim/features/implementation
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
  test "resolves method implementations by receiver type":
    let text = """type Left = object
  value*: int
type Right = object
  value*: int
method render*(item: Left) = discard
method render*(item: Right) = discard
proc use(item: Left) = discard item.render()
"""
    let workspace = initWorkspace()
    let fileId = workspace.openDocument(
      "file:///tmp/onim-method-implementations.nim",
      "/tmp/onim-method-implementations.nim", text, 1,
    )
    let snapshot = workspace.snapshotForFile(fileId)
    let callOffset = text.rfind("item.render") + "item.".len + 1
    let target = resolveDefinition(workspace, snapshot, callOffset)
    check target.kind == definitionResolved
    let implementations = implementationTargets(workspace, snapshot, callOffset)
    check implementations.len == 1
    if implementations.len == 1:
      check implementations[0].fileId.value == fileId.value
      check implementations[0].nameToken == target.target.nameToken

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

    let sequenceText = """type Item = object
  name: string
type Other = object
proc itemCount(items: seq[Item]) = discard
proc otherCount(items: seq[Other]) = discard
proc use(items: seq[Item]) =
  discard items.itemCount
proc useOther(items: seq[Other]) =
  discard items.itemCount
proc useField(items: seq[Item]) =
  discard items[0].name
"""
    let sequenceWorkspace = initWorkspace()
    let sequenceId = sequenceWorkspace.openDocument(
      "file:///tmp/onim-sequence-ufcs.nim", "/tmp/onim-sequence-ufcs.nim", sequenceText,
      1,
    )
    let sequenceSnapshot = sequenceWorkspace.snapshotForFile(sequenceId)
    let sequenceMatch = resolveDefinition(
      sequenceWorkspace,
      sequenceSnapshot,
      sequenceText.find("items.itemCount") + "items.".len + 2,
    )
    check sequenceMatch.kind == definitionResolved
    check sequenceSnapshot.index.parsed.tokens.tokenText(
      sequenceSnapshot.index.parsed.tokens[int(sequenceMatch.target.nameToken)]
    ) == "itemCount"
    let sequenceMismatch = resolveDefinition(
      sequenceWorkspace,
      sequenceSnapshot,
      sequenceText.rfind("items.itemCount") + "items.".len + 2,
    )
    check sequenceMismatch.kind == definitionUnsupported
    let sequenceField = resolveDefinition(
      sequenceWorkspace,
      sequenceSnapshot,
      sequenceText.find("items[0].name") + "items[0].".len + 1,
    )
    check sequenceField.kind == definitionResolved
    check sequenceField.target.kind == targetObjectField
    let arrayText = """type Entry = object
  name: string
proc useArray(entries: array[2, Entry]) =
  discard entries[0].name
"""
    let arrayId = sequenceWorkspace.openDocument(
      "file:///tmp/onim-array-field.nim", "/tmp/onim-array-field.nim", arrayText, 1
    )
    let arraySnapshot = sequenceWorkspace.snapshotForFile(arrayId)
    let arrayField = resolveDefinition(
      sequenceWorkspace,
      arraySnapshot,
      arrayText.find("entries[0].name") + "entries[0].".len + 1,
    )
    check arrayField.kind == definitionResolved
    check arrayField.target.kind == targetObjectField

    let tupleSequenceText = """proc use() =
  let people = @[(name: "Ada", age: 1), (name: "Bob", age: 2)]
  discard people[0].name
"""
    let tupleSequenceWorkspace = initWorkspace()
    let tupleSequenceId = tupleSequenceWorkspace.openDocument(
      "file:///tmp/onim-tuple-sequence-field.nim", "/tmp/onim-tuple-sequence-field.nim",
      tupleSequenceText, 1,
    )
    let tupleSequenceSnapshot = tupleSequenceWorkspace.snapshotForFile(tupleSequenceId)
    let tupleSequenceField = resolveDefinition(
      tupleSequenceWorkspace,
      tupleSequenceSnapshot,
      tupleSequenceText.find("people[0].name") + "people[0].".len + 1,
    )
    check tupleSequenceField.kind == definitionResolved
    check tupleSequenceField.target.kind == targetObjectField

    let enumText = """type Color = enum
  red, green, blue
proc show() =
  discard Color.green
"""
    let enumWorkspace = initWorkspace()
    let enumId = enumWorkspace.openDocument(
      "file:///tmp/onim-enum.nim", "/tmp/onim-enum.nim", enumText, 1
    )
    let enumSnapshot = enumWorkspace.snapshotForFile(enumId)
    let enumResolution = resolveDefinition(
      enumWorkspace, enumSnapshot, enumText.find("Color.green") + "Color.".len + 1
    )
    check enumResolution.kind == definitionResolved
    check enumResolution.target.kind == targetObjectField
    check enumSnapshot.index.parsed.tokens.tokenText(
      enumSnapshot.index.parsed.tokens[int(enumResolution.target.nameToken)]
    ) == "green"

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
