import std/[json, strutils]

import ../features/definition_models
import ../features/references
import ../features/rename
import ../index/source_index
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ../syntax/tokens
import ./positions
import ./uris
import ./validation

proc appendRenameEdits(
    changes: JsonNode,
    workspace: Workspace,
    source: WorkspaceSnapshot,
    sourceUri, newName: string,
    matches: openArray[ReferenceMatch],
): bool =
  var currentFile = InvalidFileId
  var currentSource: WorkspaceSnapshot
  var currentUri = ""
  var positions: PositionIndex
  var previousEnd = -1
  for match in matches:
    if match.fileId.value != currentFile.value:
      currentFile = match.fileId
      currentSource =
        if match.fileId.value == source.fileId.value:
          source
        else:
          workspace.snapshotForFile(match.fileId)
      if not currentSource.valid or currentSource.index == nil or
          currentSource.id.value != source.id.value or
          currentSource.contentGeneration.value != match.contentGeneration.value or
          currentSource.index.contentHash != contentFingerprint(currentSource.text) or
          currentSource.index.byteLength != currentSource.text.len:
        return false
      currentUri =
        if match.fileId.value == source.fileId.value:
          sourceUri
        elif currentSource.uri.len > 0:
          currentSource.uri
        else:
          fileUri(currentSource.path)
      if currentUri.len == 0 or changes.hasKey(currentUri):
        return false
      changes[currentUri] = newJArray()
      positions = initPositionIndex(currentSource.text)
      previousEnd = -1
    elif currentSource.contentGeneration.value != match.contentGeneration.value:
      return false
    if match.tokenIndex >= uint32(currentSource.index.parsed.tokens.len):
      return false
    let token = currentSource.index.parsed.tokens[int(match.tokenIndex)]
    if token.kind != tkIdentifier or not validIdentifier(token) or token.startOffset < 0 or
        token.endOffset <= token.startOffset or token.endOffset > currentSource.text.len or
        token.startOffset < previousEnd:
      return false
    changes[currentUri].add %*{
      "range": {
        "start": positionAt(positions, currentSource.text, token.startOffset),
        "end": positionAt(positions, currentSource.text, token.endOffset),
      },
      "newText": newName,
    }
    previousEnd = token.endOffset
  true

proc renameResponse*(
    params: JsonNode, workspace: Workspace, stdlib: StdlibMap = nil
): tuple[value: JsonNode, needsBootstrap: bool] =
  result.value = newJNull()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString or not params.hasKey("newName") or
      params["newName"].kind != JString:
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
  let info =
    resolveRename(workspace, snapshot, offset, params["newName"].getStr, stdlib)
  if info.state != renameAvailable:
    result.needsBootstrap = workspace.bootstrapPending
    return
  var changes = newJObject()
  if not appendRenameEdits(
    changes, workspace, snapshot, uriText, params["newName"].getStr, info.matches
  ):
    return
  result.value = %*{"changes": changes}

proc prepareRenameResponse*(
    params: JsonNode, workspace: Workspace
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
  let snapshot = workspace.snapshotForDocument(uriText, path)
  if not snapshot.valid or snapshot.index == nil:
    return
  let positions = initPositionIndex(snapshot.text)
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let references = resolveReferences(workspace, snapshot, offset, true)
  result.needsBootstrap = not references.supported and workspace.bootstrapPending
  if not references.supported or references.matches.len == 0 or
      references.target.kind != targetDeclaration:
    return
  let tokenIndex = tokenAtOffset(snapshot.index.parsed.tokens, offset)
  if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
    return
  let token = snapshot.index.parsed.tokens[tokenIndex]
  if token.kind != tkIdentifier or not validIdentifier(token) or token.startOffset < 0 or
      token.endOffset <= token.startOffset or token.endOffset > snapshot.text.len:
    return
  result.value = %*{
    "start": positionAt(positions, snapshot.text, token.startOffset),
    "end": positionAt(positions, snapshot.text, token.endOffset),
  }
