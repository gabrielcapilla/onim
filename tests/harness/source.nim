import std/os except FileId
import std/[strutils, tables]

import ./fixture
import onim/index/source_index
import onim/protocol/uris
import onim/session/ids
import onim/session/workspace
import onim/session/workspace_models

proc fixtureSnapshot*(fixture: Fixture, path = "main.nim"): WorkspaceSnapshot =
  if not fixture.files.hasKey(path):
    raise newException(ValueError, "fixture file is missing: " & path)
  var ordinal = 0'u32
  for name in fixture.files.keys:
    inc ordinal
    if name == path:
      result = WorkspaceSnapshot(
        valid: true,
        id: SnapshotId(1),
        fileId: FileId(ordinal),
        path: path,
        text: fixture.files[path],
        contentGeneration: ContentGeneration(1),
        index: indexSource(fixture.files[path]),
      )
      return
  raise newException(ValueError, "fixture file is missing: " & path)

proc fixturePath(root, path: string): string {.inline.} =
  let relative = path.strip(chars = {'/', '\\'})
  if relative.len == 0:
    root / "main.nim"
  else:
    root / relative

proc openFixtureDocuments*(
    workspace: Workspace, fixture: Fixture, root: string
): seq[FileId] =
  if workspace == nil or root.len == 0:
    return
  for path, text in fixture.files:
    let documentPath = fixturePath(root, path)
    result.add workspace.openDocument(fileUri(documentPath), documentPath, text, 1)

proc fixtureWorkspaceSnapshot*(
    workspace: Workspace, fixture: Fixture, root, path = "main.nim"
): WorkspaceSnapshot =
  if workspace == nil or root.len == 0 or not fixture.files.hasKey(path):
    return
  let documentPath = fixturePath(root, path)
  discard
    workspace.openDocument(fileUri(documentPath), documentPath, fixture.files[path], 1)
  workspace.snapshotForDocument(fileUri(documentPath), documentPath)
