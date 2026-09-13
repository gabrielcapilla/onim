import std/[json, strutils]

import ../features/completion
import ../features/completion_models
import ../features/organize_edits
import ../features/organize_planning
import ../session/workspace
import ../session/workspace_models
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

proc completionDetail(label, detail: string): string {.inline.} =
  if detail.len == 0 or label.len == 0:
    return detail
  let lines = detail.splitLines()
  let firstLine = lines[0].strip
  var nameStart = firstLine.find(label)
  while nameStart >= 0:
    let namePast = nameStart + label.len
    let startsIdentifier =
      nameStart > 0 and
      (firstLine[nameStart - 1].isAlphaNumeric or firstLine[nameStart - 1] == '_')
    let endsIdentifier =
      namePast < firstLine.len and
      (firstLine[namePast].isAlphaNumeric or firstLine[namePast] == '_')
    if not startsIdentifier and not endsIdentifier:
      break
    nameStart = firstLine.find(label, namePast)
  if nameStart < 0:
    return detail
  let namePast = nameStart + label.len
  if namePast == firstLine.len or firstLine[namePast].isAlphaNumeric or
      firstLine[namePast] == '_':
    return detail
  result = firstLine[namePast .. ^1]
  if lines.len > 1:
    for line in lines[1 .. ^1]:
      result.add '\n'
      result.add line

proc completionDocumentation(item: CompletionItem, detail: string): string =
  result = item.documentation
  if detail.len == 0 and item.detail.len > 0:
    result = "```nim\n" & item.detail & "\n```"
    if item.documentation.len > 0:
      result.add "\n\n"
      result.add item.documentation

proc additionalImportEdits(
    source: WorkspaceSnapshot,
    item: CompletionItem,
    stdlib: StdlibMap,
    positions: PositionIndex,
    useStdPrefix: bool,
): JsonNode =
  result = newJArray()
  if item.autoImportModule.len == 0 or not source.valid or source.index == nil:
    return
  let candidate = SymbolCandidate(module: item.autoImportModule, name: item.label)
  let newline = if source.text.contains("\r\n"): "\r\n" else: "\n"
  let edits = renderImportAdditions(
    source.text,
    source.index.parsed,
    @[PlannedImport(candidate: candidate)],
    stdlib,
    useStdPrefix,
    newline,
  )
  for edit in edits:
    result.add %*{
      "range": {
        "start": positionAt(positions, source.text, edit.startOffset),
        "end": positionAt(positions, source.text, edit.endOffset),
      },
      "newText": edit.newText,
    }

proc completionResponse*(
    params: JsonNode,
    workspace: Workspace,
    stdlib: StdlibMap,
    useStdPrefix: bool,
    insertReplaceSupport: bool,
    snippetSupport: bool,
): tuple[value: JsonNode, needsBootstrap: bool] =
  result.value = newJNull()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString:
    return
  let uriText = textDocument["uri"].getStr
  let path = uriToPath(uriText)
  if path.len == 0 or path.toLowerAscii.endsWith(".nimble") or
      path.toLowerAscii.endsWith(".cfg"):
    return
  let snapshot = workspace.snapshotForOpenDocument(uriText, path)
  if not snapshot.valid or snapshot.index == nil:
    result.value = %*{"isIncomplete": true, "items": []}
    return
  let positions = initPositionIndex(snapshot.text)
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let completion = completeAt(workspace, snapshot, offset, stdlib)
  if completion.needsBootstrap:
    result.needsBootstrap = true
    return
  if completion.state != completionAvailable:
    return
  let insertStart = positionAt(positions, snapshot.text, completion.insertStart)
  let insertEnd = positionAt(positions, snapshot.text, completion.insertEnd)
  let replaceStart = positionAt(positions, snapshot.text, completion.replaceStart)
  let replaceEnd = positionAt(positions, snapshot.text, completion.replaceEnd)
  var items = newJArray()
  for item in completion.items:
    let useSnippet = snippetSupport and item.snippetText.len > 0
    let newText = if useSnippet: item.snippetText else: item.label
    let textEdit =
      if insertReplaceSupport:
        %*{
          "newText": newText,
          "insert": {"start": insertStart, "end": insertEnd},
          "replace": {"start": replaceStart, "end": replaceEnd},
        }
      else:
        %*{"newText": newText, "range": {"start": replaceStart, "end": replaceEnd}}
    var value = %*{
      "label": item.label, "kind": completionItemKind(item.kind), "textEdit": textEdit
    }
    if useSnippet:
      value["insertTextFormat"] = %2
    let detail = completionDetail(item.label, item.detail)
    if detail.len > 0:
      value["detail"] = %detail
    let documentation = completionDocumentation(item, detail)
    if documentation.len > 0:
      value["documentation"] = %*{"kind": "markdown", "value": documentation}
    if item.filterText.len > 0:
      value["filterText"] = %item.filterText
    if item.sortText.len > 0:
      value["sortText"] = %item.sortText
    let importEdits =
      additionalImportEdits(snapshot, item, stdlib, positions, useStdPrefix)
    if importEdits.len > 0:
      value["additionalTextEdits"] = importEdits
    items.add value
  result.value = %*{"isIncomplete": false, "items": items}
