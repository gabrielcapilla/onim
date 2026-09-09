import std/[json, strutils]

import ../features/implementation
import ../features/references
import ../session/workspace
import ./locations
import ./positions
import ./uris
import ./validation

proc implementationResponse*(
    params: JsonNode, workspace: Workspace
): tuple[value: JsonNode, needsBootstrap: bool] =
  result.value = newJArray()
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
  if not source.valid:
    return
  let positions = initPositionIndex(source.text)
  let offset = offsetAt(positions, source.text, valueOrEmpty(params, "position"))
  let targets = implementationTargets(workspace, source, offset)
  if targets.len == 0:
    result.needsBootstrap = workspace.bootstrapPending
    if result.needsBootstrap:
      result.value = newJNull()
    return
  for target in targets:
    let view = workspace.indexViewForFile(target.fileId)
    let location = definitionLocation(source, uriText, view, target, positions)
    if location != nil:
      result.value.add location

proc referencesResponse*(
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
  let context = valueOrEmpty(params, "context")
  let includeDeclaration =
    context.kind == JObject and context.hasKey("includeDeclaration") and
    context["includeDeclaration"].kind == JBool and context["includeDeclaration"].getBool
  let references = resolveReferences(workspace, snapshot, offset, includeDeclaration)
  if not references.supported:
    result.needsBootstrap = workspace.bootstrapPending
    return
  result.value = newJArray()
  if not appendReferenceLocations(
    result.value, workspace, snapshot, uriText, references.matches
  ):
    result.value = newJNull()
