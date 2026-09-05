import std/[strutils, unittest]

import onim/features/rename
import onim/session/workspace

proc renameFor(source, wanted, newName: string): RenameInfo =
  let workspace = initWorkspace()
  let path = "/tmp/onim-rename-test.nim"
  let uri = "file:///tmp/onim-rename-test.nim"
  discard workspace.openDocument(uri, path, source, 1)
  let snapshot = workspace.snapshotForDocument(uri, path)
  renameLocal(workspace, snapshot, source.rfind(wanted) + 1, newName)

suite "native rename":
  test "renames a local declaration and its uses":
    let info = renameFor(
      "proc sum(value: int) =\n  let doubled = value\n  echo doubled\n", "doubled",
      "scaled",
    )
    check info.state == renameAvailable
    check info.tokens.len == 2

  test "rejects invalid names and unsupported top-level bindings":
    check renameFor("proc sum(value: int) =\n  echo value\n", "value", "when").state ==
      renameUnavailable
    check renameFor("let value = 1\necho value\n", "value", "scaled").state ==
      renameUnavailable
