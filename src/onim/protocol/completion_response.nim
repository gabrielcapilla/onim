import std/[json, strutils]

import ../features/completion
import ../features/completion_models
import ../session/workspace
import ../stdlib/map
import ./positions
import ./uris
import ./validation

proc completionItemKind(kind: CompletionKind): int {.inline.} =
  case kind
  of completionVariable: 6
  of completionConstant: 21
  of completionFunction: 3
  of completionMethod: 2
  of completionField: 5
  of completionType: 7

proc completionResponse*(
    params: JsonNode, workspace: Workspace, stdlib: StdlibMap
): JsonNode =
  result = newJNull()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString:
    return
  let uriText = textDocument["uri"].getStr
  let path = uriToPath(uriText)
  if path.len == 0 or path.toLowerAscii.endsWith(".nimble") or
      path.toLowerAscii.endsWith(".cfg"):
    return
  let snapshot = workspace.snapshotForDocument(uriText, path)
  if not snapshot.valid or snapshot.index == nil:
    return
  let positions = initPositionIndex(snapshot.text)
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let completion = completeAt(workspace, snapshot, offset, stdlib)
  if completion.state != completionAvailable:
    return
  let start = positionAt(positions, snapshot.text, completion.replaceStart)
  let finish = positionAt(positions, snapshot.text, completion.replaceEnd)
  var items = newJArray()
  for item in completion.items:
    items.add %*{
      "label": item.label,
      "kind": completionItemKind(item.kind),
      "textEdit": {"range": {"start": start, "end": finish}, "newText": item.label},
    }
  result = %*{"isIncomplete": true, "items": items}
