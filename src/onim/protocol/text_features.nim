import std/[json, strutils]

import ../features/inlay
import ../features/references
import ../index/symbols
import ../index/type_ids
import ../index/type_index_models
import ../index/type_kinds
import ../index/types
import ../session/ids
import ../session/module_catalog
import ../session/workspace
import ../session/workspace_models
import ../syntax/imports
import ../syntax/include_parser
import ../syntax/parser
import ../syntax/tokens
import ./positions
import ./uris
import ./validation

proc documentSymbolKind*(kind: SourceSymbolKind): int =
  case kind
  of symbolMethod:
    6
  of symbolType:
    23
  of symbolVar, symbolLet:
    13
  of symbolConst:
    14
  of symbolProc, symbolFunc, symbolIterator, symbolMacro, symbolTemplate,
      symbolConverter:
    12

proc documentSymbols*(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
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
  for symbol in snapshot.index.symbols:
    let tokenIndex = int(symbol.nameToken)
    if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
      continue
    let token = snapshot.index.parsed.tokens[tokenIndex]
    if token.kind != tkIdentifier or token.startOffset < 0 or
        token.endOffset > snapshot.text.len or token.endOffset <= token.startOffset:
      continue
    let start = positionAt(positions, snapshot.text, token.startOffset)
    let finish = positionAt(positions, snapshot.text, token.endOffset)
    result.add %*{
      "name": snapshot.index.parsed.tokens.tokenText(token),
      "kind": documentSymbolKind(symbol.kind),
      "range": {"start": start, "end": finish},
      "selectionRange": {"start": start, "end": finish},
    }

proc inlayTypeLabel(
    types: TypeIndex, tokens: TokenStore, id: TypeId, depth: uint8 = 0'u8
): string =
  if not id.valid or depth > 4'u8:
    return
  let ordinal = int(uint32(id)) - 1
  if ordinal < 0 or ordinal >= types.records.len:
    return
  let record = types.records[ordinal]
  if record.kind.isPrimitiveType:
    return record.kind.primitiveTypeName
  case record.kind
  of typeNamed:
    if record.nameToken < uint32(tokens.len):
      result = tokens.tokenText(tokens[int(record.nameToken)])
  of typeSeq:
    let base = inlayTypeLabel(types, tokens, record.baseType, depth + 1'u8)
    if base.len > 0:
      result = "seq[" & base & "]"
  of typeRef:
    let base = inlayTypeLabel(types, tokens, record.baseType, depth + 1'u8)
    if base.len > 0:
      result = "ref " & base
  of typeArray:
    let base = inlayTypeLabel(types, tokens, record.baseType, depth + 1'u8)
    if base.len > 0:
      result = "array[" & $record.extent & ", " & base & "]"
  of typeGenericInstance:
    if record.nameToken < uint32(tokens.len):
      let base = inlayTypeLabel(types, tokens, record.baseType, depth + 1'u8)
      if base.len > 0:
        result = tokens.tokenText(tokens[int(record.nameToken)]) & "[" & base & "]"
  of typeUnknown:
    result = ""
  else:
    discard

proc inlayHints*(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString:
    return
  let uriText = textDocument["uri"].getStr
  let path = uriToPath(uriText)
  if path.len == 0 or path.toLowerAscii.endsWith(".nimble") or
      path.toLowerAscii.endsWith(".cfg"):
    return
  let source = workspace.snapshotForDocument(uriText, path)
  if not source.valid or source.index == nil:
    return
  let positions = initPositionIndex(source.text)
  let range = params["range"]
  let firstOffset = offsetAt(positions, source.text, range["start"])
  let pastOffset = offsetAt(positions, source.text, range["end"])
  if firstOffset < 0 or pastOffset < firstOffset:
    return
  for hint in inferredInlayHints(workspace, source, firstOffset, pastOffset):
    if hint.declarationToken >= uint32(source.index.parsed.tokens.len):
      continue
    let token = source.index.parsed.tokens[int(hint.declarationToken)]
    if token.endOffset <= token.startOffset or token.endOffset > source.text.len:
      continue
    let typeSource = workspace.snapshotForFile(hint.typeResolution.fileId)
    if not typeSource.valid or typeSource.index == nil or
        typeSource.id.value != hint.typeResolution.snapshotId.value or
        typeSource.contentGeneration.value != hint.typeResolution.contentGeneration.value:
      continue
    let label = inlayTypeLabel(
      typeSource.index.types, typeSource.index.parsed.tokens,
      hint.typeResolution.info.typeId,
    )
    if label.len == 0:
      continue
    result.add %*{
      "position": positionAt(positions, source.text, token.endOffset),
      "label": ": " & label,
      "kind": 1,
      "paddingLeft": true,
    }

proc workspaceSymbols*(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
  let query = identifierKey(params["query"].getStr)
  for fileId in workspace.fileIds:
    let snapshot = workspace.snapshotForFile(fileId)
    if not snapshot.valid or snapshot.index == nil or
        snapshot.path.toLowerAscii.endsWith(".nimble") or
        snapshot.path.toLowerAscii.endsWith(".cfg"):
      continue
    let positions = initPositionIndex(snapshot.text)
    let uriText =
      if snapshot.uri.len > 0:
        snapshot.uri
      else:
        fileUri(snapshot.path)
    for symbol in snapshot.index.symbols:
      let tokenIndex = int(symbol.nameToken)
      if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
        continue
      let token = snapshot.index.parsed.tokens[tokenIndex]
      if token.kind != tkIdentifier or token.startOffset < 0 or
          token.endOffset > snapshot.text.len or token.endOffset <= token.startOffset:
        continue
      let name = snapshot.index.parsed.tokens.tokenText(token)
      if query.len > 0 and
          not snapshot.index.parsed.tokens.identifierContainsKey(token, query):
        continue
      let start = positionAt(positions, snapshot.text, token.startOffset)
      let finish = positionAt(positions, snapshot.text, token.endOffset)
      result.add %*{
        "name": name,
        "kind": documentSymbolKind(symbol.kind),
        "location": {"uri": uriText, "range": {"start": start, "end": finish}},
      }

proc addDocumentLink(
    links: var JsonNode,
    workspace: Workspace,
    source: WorkspaceSnapshot,
    positions: PositionIndex,
    item: ImportInfo,
): bool =
  if workspace == nil or not source.valid or source.index == nil or item.synthetic or
      item.conditional or item.module.len == 0 or item.moduleStartOffset < 0 or
      item.moduleEndOffset <= item.moduleStartOffset or
      item.moduleEndOffset > source.text.len:
    return
  let catalog = workspace.moduleCatalog()
  if catalog == nil or not catalog.complete:
    return
  let resolved =
    catalog.resolveModuleName(workspace.moduleForPath(source.path), item.module)
  if resolved.kind != moduleResolved:
    return
  let targetId = workspace.resolveModule(source.fileId, item.module)
  if not targetId.valid or targetId.value != resolved.id.value:
    return
  let target = workspace.indexViewForFile(targetId)
  if not target.valid or target.path.len == 0:
    return
  let targetUri =
    if target.uri.len > 0:
      target.uri
    else:
      fileUri(target.path)
  if targetUri.len == 0:
    return
  links.add %*{
    "range": {
      "start": positionAt(positions, source.text, item.moduleStartOffset),
      "end": positionAt(positions, source.text, item.moduleEndOffset),
    },
    "target": targetUri,
  }
  true

proc documentLinks*(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
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
  for item in snapshot.index.parsed.imports:
    discard addDocumentLink(result, workspace, snapshot, positions, item)
  for node in snapshot.index.syntax.nodes:
    if node.kind != syntaxInclude or node.uncertainty != {}:
      continue
    let parsed = parseIncludeReferences(
      snapshot.index.parsed.tokens, snapshot.text, int(node.firstToken)
    )
    if parsed.uncertainty != {} or parsed.next != int(node.pastToken):
      continue
    for item in parsed.references:
      discard addDocumentLink(result, workspace, snapshot, positions, item)

proc documentHighlights*(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
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
  if offset < 0:
    return
  let references = resolveSameFileReferences(workspace, snapshot, offset, true)
  if not references.supported:
    return
  for tokenIndex in references.tokens:
    if tokenIndex >= uint32(snapshot.index.parsed.tokens.len):
      continue
    let token = snapshot.index.parsed.tokens[int(tokenIndex)]
    if token.startOffset < 0 or token.endOffset <= token.startOffset or
        token.endOffset > snapshot.text.len:
      continue
    result.add %*{
      "range": {
        "start": positionAt(positions, snapshot.text, token.startOffset),
        "end": positionAt(positions, snapshot.text, token.endOffset),
      },
      "kind": 1,
    }

proc foldingRanges*(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
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
  for node in snapshot.index.syntax.nodes:
    if node.kind notin {syntaxWhen, syntaxBlock, syntaxDeclaration} or
        node.uncertainty != {}:
      continue
    let first = int(node.firstToken)
    let past = int(node.pastToken)
    if first < 0 or past <= first or past > snapshot.index.parsed.tokens.len:
      continue
    let startLine = snapshot.index.parsed.tokens[first].line
    let endLine = snapshot.index.parsed.tokens[past - 1].line
    if startLine < 0 or endLine <= startLine:
      continue
    result.add %*{"startLine": startLine, "endLine": endLine}

proc selectionRangeItem(
    source: string, positions: PositionIndex, startOffset, endOffset: int
): JsonNode =
  %*{
    "start": positionAt(positions, source, startOffset),
    "end": positionAt(positions, source, endOffset),
  }

proc selectionRanges*(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
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
  for position in params["positions"].items:
    let offset = offsetAt(positions, snapshot.text, position)
    if offset < 0:
      continue
    var spans: seq[tuple[startOffset, endOffset: int]] = @[]
    let tokenIndex = tokenContaining(snapshot.index.parsed.tokens, offset, offset)
    if tokenIndex >= 0:
      let token = snapshot.index.parsed.tokens[tokenIndex]
      spans.add (token.startOffset, token.endOffset)
      var nodeIndex = -1
      for candidateIndex, node in snapshot.index.syntax.nodes:
        if candidateIndex == 0 or node.firstToken > uint32(tokenIndex) or
            node.pastToken <= uint32(tokenIndex):
          continue
        if nodeIndex < 0 or
            node.pastToken - node.firstToken <
            snapshot.index.syntax.nodes[nodeIndex].pastToken -
            snapshot.index.syntax.nodes[nodeIndex].firstToken:
          nodeIndex = candidateIndex
      while nodeIndex > 0 and nodeIndex < snapshot.index.syntax.nodes.len:
        let node = snapshot.index.syntax.nodes[nodeIndex]
        let first = int(node.firstToken)
        let past = int(node.pastToken)
        if first >= 0 and past > first and past <= snapshot.index.parsed.tokens.len:
          spans.add (
            snapshot.index.parsed.tokens[first].startOffset,
            snapshot.index.parsed.tokens[past - 1].endOffset,
          )
        let parent = int(uint32(node.parent)) - 1
        if parent <= 0 or parent >= snapshot.index.syntax.nodes.len:
          break
        nodeIndex = parent
    if spans.len == 0:
      spans.add (0, snapshot.text.len)
    elif spans[^1].startOffset != 0 or spans[^1].endOffset != snapshot.text.len:
      spans.add (0, snapshot.text.len)
    var parent: JsonNode
    for spanIndex in countdown(spans.high, 0):
      var item = newJObject()
      item["range"] = selectionRangeItem(
        snapshot.text,
        positions,
        spans[spanIndex].startOffset,
        spans[spanIndex].endOffset,
      )
      if parent != nil:
        item["parent"] = parent
      parent = item
    result.add parent
