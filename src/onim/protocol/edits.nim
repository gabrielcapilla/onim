import std/json

import ../features/organize
import ../features/organize_edits
import ./positions

proc editJson(source: string, positions: PositionIndex, edit: ImportEdit): JsonNode =
  %*{
    "range": {
      "start": positionAt(positions, source, edit.startOffset),
      "end": positionAt(positions, source, edit.endOffset),
    },
    "newText": edit.newText,
  }

proc renderCodeActions*(uriText, source: string, edits: seq[ImportEdit]): JsonNode =
  if edits.len == 0:
    return newJArray()
  let positions = initPositionIndex(source)
  var uriEdits = newJArray()
  for edit in edits:
    uriEdits.add editJson(source, positions, edit)
  var workspaceEdit = newJObject()
  workspaceEdit["changes"] = newJObject()
  workspaceEdit["changes"][uriText] = uriEdits
  var action = newJObject()
  action["title"] = %"Organize Nim imports"
  action["kind"] = %"source.organizeImports"
  action["edit"] = workspaceEdit
  result = newJArray()
  result.add action
