import std/json

import ../features/definition_models
import ../features/references
import ../session/workspace
import ../session/workspace_models
import ../session/ids
import ../syntax/tokens
import ./positions
import ./uris

proc targetTokenLength(tokens: TokenStore, token: Token): int =
  let byteLength = token.endOffset - token.startOffset
  let text = tokens.tokenText(token)
  if byteLength == text.len:
    return utf16Length(text)
  if byteLength == text.len + 2:
    return utf16Length(text) + 2
  -1

proc definitionLocation*(
    source: WorkspaceSnapshot,
    sourceUri: string,
    view: WorkspaceIndexView,
    target: DefinitionTarget,
    positions: PositionIndex,
): JsonNode =
  if not view.valid or view.index == nil or view.id.value != target.snapshotId.value or
      view.contentGeneration.value != target.contentGeneration.value or
      int(target.nameToken) >= view.index.parsed.tokens.len:
    return
  let token = view.index.parsed.tokens[int(target.nameToken)]
  let uri =
    if view.uri.len > 0:
      view.uri
    else:
      fileUri(view.path)
  var start: JsonNode
  var finish: JsonNode
  if view.fileId.value == source.fileId.value:
    start = positionAt(positions, source.text, token.startOffset)
    finish = positionAt(positions, source.text, token.endOffset)
  else:
    let length = targetTokenLength(view.index.parsed.tokens, token)
    if token.line < 0 or token.column < 0 or length < 0:
      return
    start = %*{"line": token.line, "character": token.column}
    finish = %*{"line": token.line, "character": token.column + length}
  %*{
    "uri": if view.fileId.value == source.fileId.value: sourceUri else: uri,
    "range": {"start": start, "end": finish},
  }

proc referenceLocation*(
    uri: string, source: WorkspaceSnapshot, token: Token, positions: PositionIndex
): JsonNode =
  if token.startOffset < 0 or token.endOffset < token.startOffset or
      token.endOffset > source.text.len:
    return
  %*{
    "uri": uri,
    "range": {
      "start": positionAt(positions, source.text, token.startOffset),
      "end": positionAt(positions, source.text, token.endOffset),
    },
  }

proc appendReferenceLocations*(
    values: JsonNode,
    workspace: Workspace,
    source: WorkspaceSnapshot,
    sourceUri: string,
    matches: openArray[ReferenceMatch],
): bool =
  var currentFile = InvalidFileId
  var currentGeneration = InvalidContentGeneration
  var currentSource: WorkspaceSnapshot
  var currentUri = ""
  var positions: PositionIndex
  for match in matches:
    if match.fileId.value != currentFile.value:
      currentFile = match.fileId
      currentSource =
        if match.fileId.value == source.fileId.value:
          source
        else:
          workspace.snapshotForFile(match.fileId)
      if not currentSource.valid or currentSource.index == nil:
        return false
      currentGeneration = currentSource.contentGeneration
      if currentGeneration.value != match.contentGeneration.value:
        return false
      currentUri =
        if match.fileId.value == source.fileId.value:
          sourceUri
        elif currentSource.uri.len > 0:
          currentSource.uri
        else:
          fileUri(currentSource.path)
      positions = initPositionIndex(currentSource.text)
    elif currentGeneration.value != match.contentGeneration.value:
      return false
    if match.tokenIndex >= uint32(currentSource.index.parsed.tokens.len):
      return false
    let location = referenceLocation(
      currentUri,
      currentSource,
      currentSource.index.parsed.tokens[int(match.tokenIndex)],
      positions,
    )
    if location == nil:
      return false
    values.add location
  true
