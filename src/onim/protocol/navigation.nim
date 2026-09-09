import std/[json, strutils]

import ../features/definition
import ../features/definition_models
import ../features/hover
import ../features/signature
import ../index/symbols
import ../index/type_ids
import ../index/type_queries
import ../index/type_states
import ../index/types
import ../session/ids
import ../session/workspace
import ../stdlib/map
import ../syntax/tokens
import ./locations
import ./positions
import ./uris
import ./validation

proc definitionResponse*(
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
  if not snapshot.valid:
    return
  let positions = initPositionIndex(snapshot.text)
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let resolution = resolveDefinition(workspace, snapshot, offset)
  result.needsBootstrap = resolution.kind == definitionUnresolved
  if resolution.kind != definitionResolved:
    return
  let view = workspace.indexViewForFile(resolution.target.fileId)
  result.value =
    definitionLocation(snapshot, uriText, view, resolution.target, positions)
  if result.value == nil:
    result.value = newJNull()

proc typeDefinitionResponse*(params: JsonNode, workspace: Workspace): JsonNode =
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
  let source = workspace.snapshotForDocument(uriText, path)
  if not source.valid or source.index == nil:
    return
  let positions = initPositionIndex(source.text)
  let offset = offsetAt(positions, source.text, valueOrEmpty(params, "position"))
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, offset)
  if tokenIndex < 0:
    return
  let resolution = resolveDefinitionAtToken(workspace, source, tokenIndex)
  if resolution.kind != definitionResolved:
    return
  let declarationView = workspace.indexViewForFile(resolution.target.fileId)
  if not declarationView.valid or declarationView.index == nil:
    return
  let declarationSymbol =
    declarationView.index.symbols.symbolToken(resolution.target.nameToken)
  if declarationSymbol >= 0 and
      declarationView.index.symbols[declarationSymbol].kind == symbolType:
    result =
      definitionLocation(source, uriText, declarationView, resolution.target, positions)
    return

  let declarationSource =
    if resolution.target.fileId.value == source.fileId.value:
      source
    else:
      workspace.snapshotForFile(resolution.target.fileId)
  if not declarationSource.valid or declarationSource.index == nil:
    return
  let localType =
    workspace.resolveLocalType(declarationSource, resolution.target.nameToken)
  if localType.info.state != typeStateResolved or
      source.index.types.namedTypeId(localType.info.typeId) == InvalidTypeId or
      localType.info.typeToken == InvalidTypeToken:
    return
  let typeSource =
    if localType.fileId.value == declarationSource.fileId.value:
      declarationSource
    else:
      workspace.snapshotForFile(localType.fileId)
  if not typeSource.valid or typeSource.index == nil or
      typeSource.id.value != localType.snapshotId.value or
      typeSource.contentGeneration.value != localType.contentGeneration.value:
    return
  let typeResolution =
    resolveDefinitionAtToken(workspace, typeSource, int(localType.info.typeToken))
  if typeResolution.kind != definitionResolved:
    return
  let typeView = workspace.indexViewForFile(typeResolution.target.fileId)
  result =
    definitionLocation(source, uriText, typeView, typeResolution.target, positions)

proc hoverResponse*(
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
  let info = resolveHover(workspace, snapshot, offset, stdlib)
  if info.state != hoverAvailable:
    return
  let tokenIndex = tokenAtOffset(snapshot.index.parsed.tokens, offset)
  if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
    return
  let token = snapshot.index.parsed.tokens[tokenIndex]
  var value = "```nim\n"
  if info.signature.len > 0:
    value.add info.signature
  elif info.kind.len > 0:
    value.add info.kind & " " & info.name
  else:
    value.add info.name
  value.add "\n```"
  if info.module.len > 0:
    value.add "\n\n*Module:* `" & info.module & "`"
  if info.documentation.len > 0:
    value.add "\n\n" & info.documentation
  result = %*{
    "contents": {"kind": "markdown", "value": value},
    "range": {
      "start": positionAt(positions, snapshot.text, token.startOffset),
      "end": positionAt(positions, snapshot.text, token.endOffset),
    },
  }

proc signatureHelpResponse*(
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
  let info = resolveSignatureHelp(workspace, snapshot, offset, stdlib)
  if info.state != signatureAvailable:
    return
  var signatures = newJArray()
  for signature in info.signatures:
    var parameters = newJArray()
    for parameter in signature.parameters:
      parameters.add %*{"label": parameter}
    signatures.add %*{"label": signature.label, "parameters": parameters}
  if signatures.len == 0:
    return
  result = %*{
    "signatures": signatures,
    "activeSignature": 0,
    "activeParameter": info.activeParameter,
  }
