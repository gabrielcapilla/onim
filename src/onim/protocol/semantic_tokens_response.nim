import std/[json, strutils]

import ../features/semantic_tokens
import ../session/workspace
import ../syntax/tokens
import ./positions
import ./uris
import ./validation

type SemanticTokenResponseMode = enum
  semanticTokenFull
  semanticTokenRange

proc semanticTokensResponseFor(
    params: JsonNode, workspace: Workspace, mode: SemanticTokenResponseMode
): JsonNode =
  result = newJObject()
  result["data"] = newJArray()
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
  var rangeStart = -1
  var rangeEnd = -1
  if mode == semanticTokenRange:
    let range = valueOrEmpty(params, "range")
    if range.kind != JObject:
      return
    rangeStart = offsetAt(positions, snapshot.text, valueOrEmpty(range, "start"))
    rangeEnd = offsetAt(positions, snapshot.text, valueOrEmpty(range, "end"))
    if rangeStart < 0 or rangeEnd < rangeStart:
      return
  var previousLine = 0
  var previousStart = 0
  for item in semanticTokens(snapshot.index):
    if item.token >= uint32(snapshot.index.parsed.tokens.len):
      continue
    let token = snapshot.index.parsed.tokens[int(item.token)]
    if token.startOffset < 0 or token.endOffset <= token.startOffset or
        token.endOffset > snapshot.text.len:
      continue
    if mode == semanticTokenRange and
        (token.startOffset >= rangeEnd or rangeStart >= token.endOffset):
      continue
    let start = positionAt(positions, snapshot.text, token.startOffset)
    let finish = positionAt(positions, snapshot.text, token.endOffset)
    let line = start["line"].getInt
    let character = start["character"].getInt
    if finish["line"].getInt != line:
      continue
    let length = finish["character"].getInt - character
    if length <= 0:
      continue
    let deltaLine = line - previousLine
    let deltaStart =
      if deltaLine == 0:
        character - previousStart
      else:
        character
    result["data"].add %deltaLine
    result["data"].add %deltaStart
    result["data"].add %length
    result["data"].add %ord(item.kind)
    result["data"].add %0
    previousLine = line
    previousStart = character

proc semanticTokensResponse*(params: JsonNode, workspace: Workspace): JsonNode =
  semanticTokensResponseFor(params, workspace, semanticTokenFull)

proc semanticTokensRangeResponse*(params: JsonNode, workspace: Workspace): JsonNode =
  semanticTokensResponseFor(params, workspace, semanticTokenRange)
