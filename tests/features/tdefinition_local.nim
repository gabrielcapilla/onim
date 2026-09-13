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

  test "resolves project generic method implementations":
    let root =
      getTempDir() / ("onim-generic-method-implementation-" & $getCurrentProcessId())
    cleanTree(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let unresolvedPath = root / "unresolved.nim"
    let providerText =
      "type Pair*[A, B] = object\n" & "  first: A\n" & "  second: B\n" &
      "method render*(item: Pair[int, string]) = discard\n" &
      "method render*(item: Pair[int, bool]) = discard\n"
    let consumerText =
      "import provider\n" & "proc usePair(item: provider.Pair[int, string]) =\n" &
      "  discard item.render()\n" &
      "proc usePairBool(item: provider.Pair[int, bool]) =\n" &
      "  discard item.render()\n"
    writeFile(providerPath, providerText)
    writeFile(consumerPath, consumerText)
    writeFile(unresolvedPath, "include missing_module\n")
    defer:
      cleanTree(root)

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check not workspace.graphComplete
    let providerId = workspace.fileIdForPath(providerPath)
    let consumerId = workspace.fileIdForPath(consumerPath)
    let snapshot = workspace.snapshotForFile(consumerId)
    let matchOffset = consumerText.find("item.render") + "item.".len + 1
    let match = implementationTargets(workspace, snapshot, matchOffset)
    check match.len == 1
    if match.len == 1:
      check match[0].fileId.value == providerId.value
      check workspace.snapshotForFile(providerId).text.find(
        "method render*(item: Pair[int, string])"
      ) + "method ".len ==
        int(
          workspace.snapshotForFile(providerId).index.parsed.tokens[
            int(match[0].nameToken)
          ].startOffset
        )
    let mismatchOffset =
      consumerText.find("item.render", consumerText.find("usePairBool")) + "item.".len +
      1
    let mismatch = implementationTargets(workspace, snapshot, mismatchOffset)
    check mismatch.len == 1
    if mismatch.len == 1:
      check mismatch[0].fileId.value == providerId.value
      check workspace.snapshotForFile(providerId).text.find(
        "method render*(item: Pair[int, bool])"
      ) + "method ".len ==
        int(
          workspace.snapshotForFile(providerId).index.parsed.tokens[
            int(mismatch[0].nameToken)
          ].startOffset
        )

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
