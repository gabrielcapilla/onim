import std/[strutils, unittest]

import onim/features/references
import onim/index/source_index
import onim/session/ids
import onim/session/workspace
import onim/syntax/lexer

proc snapshotFor(text: string): WorkspaceSnapshot =
  let index = indexSource(text)
  WorkspaceSnapshot(
    valid: true,
    id: SnapshotId(1),
    fileId: FileId(1),
    path: "references.nim",
    text: text,
    state: workspaceOpen,
    contentGeneration: ContentGeneration(1),
    dependencyGeneration: DependencyGeneration(1),
    configGeneration: ConfigGeneration(1),
    surfaceGeneration: SurfaceGeneration(1),
    index: index,
  )

proc tokenAt(text: string, snapshot: WorkspaceSnapshot, offset: int): uint32 =
  uint32(tokenAtOffset(snapshot.index.parsed.tokens, offset))

proc referenceOffsets(text, name: string): seq[int] =
  var cursor = 0
  while true:
    let found = text.find(name, cursor)
    if found < 0:
      break
    result.add found
    cursor = found + name.len

suite "native same-file references":
  test "resolves parameters and direct locals in source order":
    let text = """proc add(value: int) =
  let total = value + 1
  total
"""
    let snapshot = snapshotFor(text)
    let workspace = initWorkspace()
    let offsets = text.referenceOffsets("value")
    let valueReferences = resolveSameFileReferences(
      workspace, snapshot, offsets[1], includeDeclaration = true
    )
    check valueReferences.supported
    check valueReferences.tokens ==
      @[tokenAt(text, snapshot, offsets[0]), tokenAt(text, snapshot, offsets[1])]

    let totalOffsets = text.referenceOffsets("total")
    let totalReferences = resolveSameFileReferences(
      workspace, snapshot, totalOffsets[1], includeDeclaration = false
    )
    check totalReferences.supported
    check totalReferences.tokens == @[tokenAt(text, snapshot, totalOffsets[1])]

  test "matches Nim style-insensitive local names":
    let text = """proc show(foo_bar: int) =
  echo foobar
"""
    let snapshot = snapshotFor(text)
    let offsets = text.referenceOffsets("foo")
    let references = resolveSameFileReferences(
      initWorkspace(), snapshot, text.find("foobar"), includeDeclaration = true
    )
    check references.supported
    check references.tokens ==
      @[
        tokenAt(text, snapshot, offsets[0]),
        tokenAt(text, snapshot, text.find("foobar")),
      ]

  test "keeps same-name locals in separate routines":
    let text = """proc first(value: int) =
  echo value
proc second(value: int) =
  echo value
"""
    let snapshot = snapshotFor(text)
    let offsets = text.referenceOffsets("value")
    let references = resolveSameFileReferences(
      initWorkspace(), snapshot, offsets[1], includeDeclaration = true
    )
    check references.supported
    check references.tokens ==
      @[tokenAt(text, snapshot, offsets[0]), tokenAt(text, snapshot, offsets[1])]

  test "resolves a local used as a qualified receiver":
    let text = """proc show(value: Item) =
  echo value.field
"""
    let snapshot = snapshotFor(text)
    let offsets = text.referenceOffsets("value")
    let references = resolveSameFileReferences(
      initWorkspace(), snapshot, offsets[1], includeDeclaration = true
    )
    check references.supported
    check references.tokens ==
      @[tokenAt(text, snapshot, offsets[0]), tokenAt(text, snapshot, offsets[1])]

  test "supports unused locals and optional declarations":
    let text = """proc unused() =
  let value = 1
  discard
"""
    let snapshot = snapshotFor(text)
    let declaration = text.find("value")
    let withDeclaration = resolveSameFileReferences(
      initWorkspace(), snapshot, declaration, includeDeclaration = true
    )
    check withDeclaration.supported
    check withDeclaration.tokens == @[tokenAt(text, snapshot, declaration)]
    let withoutDeclaration = resolveSameFileReferences(
      initWorkspace(), snapshot, declaration, includeDeclaration = false
    )
    check withoutDeclaration.supported
    check withoutDeclaration.tokens.len == 0

  test "declines unsupported, non-local, and stale bindings":
    let nested = snapshotFor(
      """proc nested(value: int) =
  if value > 0:
    echo value
"""
    )
    check not resolveSameFileReferences(
      initWorkspace(), nested, nested.text.rfind("value"), true
    ).supported

    let moduleLevel = snapshotFor("let value = 1\necho value\n")
    check not resolveSameFileReferences(
      initWorkspace(), moduleLevel, moduleLevel.text.rfind("value"), true
    ).supported

    let ordered = snapshotFor(
      """proc ordered() =
  echo value
  let value = 1
"""
    )
    check not resolveSameFileReferences(
      initWorkspace(), ordered, ordered.text.find("value"), true
    ).supported

    let duplicate = snapshotFor(
      """proc duplicate() =
  let value = 1
  let value = 2
  echo value
"""
    )
    check not resolveSameFileReferences(
      initWorkspace(), duplicate, duplicate.text.rfind("value"), true
    ).supported

    var stale = snapshotFor(
      """proc stale(value: int) =
  echo value
"""
    )
    stale.text.add "\n"
    check not resolveSameFileReferences(
      initWorkspace(), stale, stale.text.rfind("value"), true
    ).supported
