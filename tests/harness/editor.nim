import std/json

import onim/features/organize
import onim/protocol/document_changes
import onim/protocol/semantic_key
import onim/session/ids
import onim/session/workspace
import onim/session/workspace_models

type EditorState* = ref object
  workspace*: Workspace

proc initEditorState*(root = ""): EditorState =
  new(result)
  result.workspace = initWorkspace(root)

proc openDocument*(editor: EditorState, uri, path, text: string, version: int64): bool =
  if editor == nil or editor.workspace == nil:
    return false
  applyDidOpen(
    editor.workspace, %*{"textDocument": {"uri": uri, "version": version, "text": text}}
  ).accepted

proc applyChange*(editor: EditorState, params: JsonNode): bool =
  if editor == nil or editor.workspace == nil:
    return false
  applyDidChange(editor.workspace, params).accepted

proc snapshot*(editor: EditorState, uri, path: string): WorkspaceSnapshot =
  if editor != nil and editor.workspace != nil:
    result = editor.workspace.snapshotForDocument(uri, path)

proc capture*(editor: EditorState, uri, path: string): SemanticKey =
  let snapshot = editor.snapshot(uri, path)
  semanticKey(snapshot, OrganizeOptions())

proc isCurrent*(editor: EditorState, stamp: SemanticKey): bool =
  if editor == nil or editor.workspace == nil or not stamp.fileId.valid:
    return false
  let snapshot = editor.workspace.snapshotForFile(stamp.fileId)
  snapshot.valid and
    sameSemanticKey(
      semanticKey(snapshot, OrganizeOptions(useStdPrefix: stamp.useStdPrefix)), stamp
    )
