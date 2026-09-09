import std/[algorithm, strutils, unittest]
import std/os except FileId

import onim/features/rename
import onim/session/ids
import onim/session/workspace
import onim/syntax/tokens

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

proc renameFor(source, wanted, newName: string): RenameInfo =
  let workspace = initWorkspace()
  let path = "/tmp/onim-rename-test.nim"
  let uri = "file:///tmp/onim-rename-test.nim"
  discard workspace.openDocument(uri, path, source, 1)
  let snapshot = workspace.snapshotForDocument(uri, path)
  resolveRename(workspace, snapshot, source.rfind(wanted) + 1, newName)

proc matchOffsets(workspace: Workspace, info: RenameInfo, path: string): seq[int] =
  let fileId = workspace.fileIdForPath(path)
  if not fileId.valid:
    return
  let snapshot = workspace.snapshotForFile(fileId)
  for match in info.matches:
    if match.fileId.value == fileId.value:
      result.add snapshot.index.parsed.tokens[int(match.tokenIndex)].startOffset
  result.sort

suite "native rename":
  test "renames a local declaration and its uses":
    let info = renameFor(
      "proc sum(value: int) =\n  let doubled = value\n  echo doubled\n", "doubled",
      "scaled",
    )
    check info.state == renameAvailable
    check info.matches.len == 2

  test "renames the parent binding without changing a block shadow":
    let info = renameFor(
      """proc show(value: int) =
  block:
    let value = 1
    echo value
  echo value
""",
      "value", "item",
    )
    check info.state == renameAvailable
    check info.matches.len == 2

  test "accepts spelling-only and Unicode identifiers":
    check renameFor("proc show(value: int) =\n  echo value\n", "value", "Value").state ==
      renameAvailable
    check renameFor("proc show(value: int) =\n  echo value\n", "value", "résultat").state ==
      renameAvailable

  test "rejects the implicit result binding":
    check renameFor("proc show(value: int) =\n  echo value\n", "value", "result").state ==
      renameUnavailable

  test "does not rename object fields":
    let source = """type Person = object
  name: string

proc show(person: Person) =
  discard person.name
"""
    check renameFor(source, "name", "label").state == renameUnavailable

  test "rejects names that are not one Nim identifier":
    let source = "proc show(value: int) =\n  echo value\n"
    check renameFor(source, "value", "when").state == renameUnavailable
    check renameFor(source, "value", "value.next").state == renameUnavailable
    check renameFor(source, "value", "value-").state == renameUnavailable
    check renameFor(source, "value", "value # comment").state == renameUnavailable

  test "rejects a local declaration collision":
    let info = renameFor(
      "proc show(value: int) =\n  let scaled = 1\n  echo value\n", "value", "scaled"
    )
    check info.state == renameUnavailable

  test "resolves exported symbols across aliases, from bindings, and unused imports":
    let root = getTempDir() / ("onim-rename-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-rename-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let aliasPath = root / "alias_consumer.nim"
    let otherPath = root / "other.nim"
    let fromPath = root / "from_consumer.nim"
    let aliasedFromPath = root / "aliased_from_consumer.nim"
    let unusedFromPath = root / "unused_from_consumer.nim"
    let providerSource = """proc answer*() = discard
proc useAnswer() =
  answer()
"""
    let aliasSource = """import provider as p
proc useAlias() =
  p.answer()
"""
    let fromSource = """import other
from provider import answer
proc useFrom() =
  answer()
"""
    let aliasedFromSource =
      "from provider import answer as local\nproc useAliased() =\n  local()\n"
    let unusedFromSource = "from provider import answer\n"
    writeFile(providerPath, providerSource)
    writeFile(aliasPath, aliasSource)
    writeFile(otherPath, "proc conflict*() = discard\n")
    writeFile(fromPath, fromSource)
    writeFile(aliasedFromPath, aliasedFromSource)
    writeFile(unusedFromPath, unusedFromSource)
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
    check workspace.graphComplete
    let providerId = workspace.fileIdForPath(providerPath)
    let providerSnapshot = workspace.snapshotForFile(providerId)
    let info = resolveRename(
      workspace, providerSnapshot, providerSource.find("answer") + 1, "response"
    )
    check info.state == renameAvailable
    check info.matches.len == 7
    check matchOffsets(workspace, info, providerPath) ==
      @[providerSource.find("answer"), providerSource.rfind("answer")]
    check matchOffsets(workspace, info, aliasPath) == @[aliasSource.rfind("answer")]
    check matchOffsets(workspace, info, fromPath) ==
      @[fromSource.find("answer"), fromSource.rfind("answer")]
    check matchOffsets(workspace, info, aliasedFromPath) ==
      @[aliasedFromSource.find("answer")]
    check matchOffsets(workspace, info, unusedFromPath) ==
      @[unusedFromSource.find("answer")]
    check resolveRename(
      workspace, providerSnapshot, providerSource.find("answer") + 1, "conflict"
    ).state == renameUnavailable

  test "rejects a stale local snapshot":
    let workspace = initWorkspace()
    let path = "/tmp/onim-stale-rename.nim"
    let uri = "file:///tmp/onim-stale-rename.nim"
    let original = "proc show(value: int) =\n  echo value\n"
    discard workspace.openDocument(uri, path, original, 1)
    let stale = workspace.snapshotForDocument(uri, path)
    discard workspace.changeDocument(uri, path, original & "\n", 2)
    check resolveRename(workspace, stale, original.rfind("value") + 1, "scaled").state ==
      renameUnavailable
