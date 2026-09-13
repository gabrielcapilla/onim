import std/[json, strutils]

import ../features/definition
import ../features/definition_models
import ../features/hover
import ../features/signature
import ../features/typo
import ../index/symbols
import ../index/type_ids
import ../index/type_queries
import ../index/type_states
import ../session/ids
import ../session/workspace
import ../stdlib/map
import ../syntax/tokens
import ./locations
import ./positions
import ./uris
import ./validation

proc hoverDeclaration(info: HoverInfo): string =
  if info.declarationText.len == 0 or info.signature.len == 0:
    return if info.declarationText.len > 0: info.declarationText else: info.signature
  if not (
    info.signature.startsWith("let ") or info.signature.startsWith("var ") or
    info.signature.startsWith("const ")
  ):
    return info.declarationText
  let declarationKindPast = if info.signature.startsWith("const "): 6 else: 4
  let signatureName = info.signature.find(info.name, declarationKindPast)
  if signatureName < 0:
    return info.declarationText
  let signatureColon = info.signature.find(':', signatureName + info.name.len)
  if signatureColon < 0 or signatureColon + 1 >= info.signature.len:
    return info.declarationText
  let typeName = info.signature[signatureColon + 1 .. ^1].strip
  if typeName.len == 0:
    return info.declarationText
  let declarationName = info.declarationText.find(info.name, declarationKindPast)
  if declarationName < 0:
    return info.declarationText
  let namePast = declarationName + info.name.len
  let equals = info.declarationText.find('=', namePast)
  if equals < 0:
    return info.declarationText
  let existingColon = info.declarationText.find(':', namePast)
  if existingColon >= 0 and existingColon < equals:
    return info.declarationText
  info.declarationText[0 ..< namePast] & ": " & typeName &
    info.declarationText[namePast .. ^1]

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

proc typeDefinitionResponse*(
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
    result.needsBootstrap =
      resolution.kind == definitionUnresolved and workspace.bootstrapPending
    return
  let declarationView = workspace.indexViewForFile(resolution.target.fileId)
  if not declarationView.valid or declarationView.index == nil:
    result.needsBootstrap = workspace.bootstrapPending
    return
  let declarationSymbol =
    declarationView.index.symbols.symbolToken(resolution.target.nameToken)
  if declarationSymbol >= 0 and
      declarationView.index.symbols[declarationSymbol].kind == symbolType:
    result.value =
      definitionLocation(source, uriText, declarationView, resolution.target, positions)
    return

  let declarationSource =
    if resolution.target.fileId.value == source.fileId.value:
      source
    else:
      workspace.snapshotForFile(resolution.target.fileId)
  if not declarationSource.valid or declarationSource.index == nil:
    result.needsBootstrap = workspace.bootstrapPending
    return
  let localType =
    workspace.resolveLocalType(declarationSource, resolution.target.nameToken)
  if localType.info.state != typeStateResolved or
      localType.info.typeToken == InvalidTypeToken:
    result.needsBootstrap =
      localType.info.state == typeStateUnresolved and workspace.bootstrapPending
    return
  let typeSource =
    if localType.fileId.value == declarationSource.fileId.value:
      declarationSource
    else:
      workspace.snapshotForFile(localType.fileId)
  if not typeSource.valid or typeSource.index == nil or
      typeSource.id.value != localType.snapshotId.value or
      typeSource.contentGeneration.value != localType.contentGeneration.value:
    result.needsBootstrap = workspace.bootstrapPending
    return
  if typeSource.index.types.namedTypeId(localType.info.typeId) == InvalidTypeId:
    return
  let typeResolution =
    resolveDefinitionAtToken(workspace, typeSource, int(localType.info.typeToken))
  if typeResolution.kind != definitionResolved:
    result.needsBootstrap =
      typeResolution.kind == definitionUnresolved and workspace.bootstrapPending
    return
  let typeView = workspace.indexViewForFile(typeResolution.target.fileId)
  result.value =
    definitionLocation(source, uriText, typeView, typeResolution.target, positions)

proc hoverResponse*(
    params: JsonNode, workspace: Workspace, stdlib: StdlibMap
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
  let info = resolveHover(workspace, snapshot, offset, stdlib)
  if info.needsBootstrap:
    result.needsBootstrap = true
    return
  if info.state != hoverAvailable:
    let tokenIndex = tokenAtOffset(snapshot.index.parsed.tokens, offset)
    if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
      return
    let token = snapshot.index.parsed.tokens[tokenIndex]
    let typo = typoAt(workspace, snapshot, token.endOffset, stdlib)
    if typo.suggestion.len == 0:
      return
    result.value = %*{
      "contents": {
        "kind": "markdown",
        "value":
          "Possible typo: `" & typo.name & "`. Did you mean `" & typo.suggestion & "`?",
      },
      "range": {
        "start": positionAt(positions, snapshot.text, typo.startOffset),
        "end": positionAt(positions, snapshot.text, typo.endOffset),
      },
    }
    return
  var rangeStart = info.rangeStartOffset
  var rangeEnd = info.rangeEndOffset
  if rangeEnd <= rangeStart:
    let tokenIndex = tokenAtOffset(snapshot.index.parsed.tokens, offset)
    if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
      return
    let token = snapshot.index.parsed.tokens[tokenIndex]
    rangeStart = token.startOffset
    rangeEnd = token.endOffset
  let declaration = hoverDeclaration(info)
  var value = "```nim\n"
  if declaration.len > 0:
    value.add declaration
  elif info.kind.len > 0:
    value.add info.kind & " " & info.name
  else:
    value.add info.name
  value.add "\n```"
  if info.module.len > 0:
    value.add "\n\n*Module:* `" & info.module & "`"
  if info.declarationLine > 0:
    value.add "\n\n*Declared at line:* " & $info.declarationLine
  if info.documentation.len > 0:
    value.add "\n\n" & info.documentation
  result.value = %*{
    "contents": {"kind": "markdown", "value": value},
    "range": {
      "start": positionAt(positions, snapshot.text, rangeStart),
      "end": positionAt(positions, snapshot.text, rangeEnd),
    },
  }

proc signatureHelpResponse*(
    params: JsonNode, workspace: Workspace, stdlib: StdlibMap
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
  let info = resolveSignatureHelp(workspace, snapshot, offset, stdlib)
  if info.needsBootstrap:
    result.needsBootstrap = true
    return
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
  result.value = %*{
    "signatures": signatures,
    "activeSignature": 0,
    "activeParameter": info.activeParameter,
  }
