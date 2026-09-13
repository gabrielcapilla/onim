import std/json

import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ./positions
import ./uris
import ./validation

type DocumentUpdate* = object
  accepted*: bool
  contentChanged*: bool
  uri*: string
  path*: string
  before*: WorkspaceSnapshot
  current*: WorkspaceSnapshot

proc materializeDocumentChange*(
    change: DocumentChange, source: string
): tuple[valid: bool, text: string] =
  if not change.valid or change.changes == nil or change.changes.len == 0:
    return
  if not change.changes[0].hasKey("range"):
    result.valid = true
    result.text = change.changes[0]["text"].getStr
    return

  var current = source
  for item in change.changes.items:
    let positions = initPositionIndex(current)
    let range = item["range"]
    let first = offsetAt(positions, current, range["start"])
    let past = offsetAt(positions, current, range["end"])
    if first < 0 or past < first:
      return
    var updated = newStringOfCap(current.len - (past - first) + item["text"].getStr.len)
    if first > 0:
      updated.add current[0 ..< first]
    updated.add item["text"].getStr
    if past < current.len:
      updated.add current[past .. ^1]
    current = updated
  result.valid = true
  result.text = current

proc applyDidOpen*(workspace: Workspace, params: JsonNode): DocumentUpdate =
  if workspace == nil or params == nil or params.kind != JObject or
      not params.hasKey("textDocument"):
    return
  let document = params["textDocument"]
  if document == nil or document.kind != JObject or not document.hasKey("uri") or
      document["uri"].kind != JString or not document.hasKey("text") or
      document["text"].kind != JString or not document.hasKey("version") or
      document["version"].kind != JInt:
    return
  result.uri = document["uri"].getStr
  result.path = uriToPath(result.uri)
  if result.path.len == 0:
    return
  discard workspace.prepareWorkspaceForDocument(result.path)
  if workspace.isOpenDocument(result.path):
    return
  let fileId = workspace.openDocument(
    result.uri, result.path, document["text"].getStr, document["version"].getInt
  )
  if not fileId.valid:
    return
  result.current = workspace.snapshotForDocument(result.uri, result.path)
  result.accepted = result.current.valid
  result.contentChanged = result.accepted

proc applyDidChange*(workspace: Workspace, params: JsonNode): DocumentUpdate =
  let change = parseDocumentChange(params)
  if workspace == nil or not change.valid:
    return
  result.uri = change.uri
  result.path = uriToPath(change.uri)
  if result.path.len == 0 or not workspace.isOpenDocument(result.path):
    return
  result.before = workspace.snapshotForFile(workspace.fileIdForPath(result.path))
  let materialized = materializeDocumentChange(change, result.before.text)
  if not materialized.valid or
      not workspace.changeDocument(
        change.uri, result.path, materialized.text, change.version
      ):
    return
  result.current = workspace.snapshotForDocument(change.uri, result.path)
  result.accepted = result.current.valid
  result.contentChanged =
    result.before.contentGeneration.value != result.current.contentGeneration.value
