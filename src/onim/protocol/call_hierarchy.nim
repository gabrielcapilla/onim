import std/[json, strutils]

import ../features/definition
import ../features/definition_models
import ../features/hierarchy
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ./locations
import ./positions
import ./text_features
import ../syntax/tokens
import ./uris
import ./validation

type HierarchyGroup = object
  target: DefinitionTarget
  ranges: seq[JsonNode]

proc callHierarchyItem(
    workspace: Workspace,
    source: WorkspaceSnapshot,
    sourceUri: string,
    target: DefinitionTarget,
    positions: PositionIndex,
): JsonNode =
  let view = workspace.indexViewForFile(target.fileId)
  let symbolIndex = view.routineSymbolIndex(target)
  if symbolIndex < 0:
    return
  let location = definitionLocation(source, sourceUri, view, target, positions)
  if location == nil:
    return
  let token = view.index.parsed.tokens[int(target.nameToken)]
  let name = view.index.parsed.tokens.tokenText(token)
  %*{
    "name": name,
    "kind": documentSymbolKind(view.index.symbols[symbolIndex].kind),
    "uri": location["uri"],
    "range": location["range"],
    "selectionRange": location["range"],
  }

proc addHierarchyGroup(
    groups: var seq[HierarchyGroup], target: DefinitionTarget, range: JsonNode
) =
  if range == nil:
    return
  for group in groups.mitems:
    if group.target.sameDefinitionTarget(target):
      group.ranges.add range
      return
  groups.add HierarchyGroup(target: target, ranges: @[range])

proc callHierarchyResponse*(
    methodName: string, params: JsonNode, workspace: Workspace
): tuple[value: JsonNode, needsBootstrap: bool] =
  result.value = newJNull()
  let item = valueOrEmpty(params, "item")
  let document =
    if methodName == "textDocument/prepareCallHierarchy":
      valueOrEmpty(params, "textDocument")
    elif item.kind == JObject:
      item
    else:
      newJObject()
  if document.kind != JObject or not document.hasKey("uri") or
      document["uri"].kind != JString:
    return
  let uriText = document["uri"].getStr
  let path = uriToPath(uriText)
  if path.len == 0 or path.toLowerAscii.endsWith(".nimble") or
      path.toLowerAscii.endsWith(".cfg"):
    return
  let source = workspace.snapshotForDocument(uriText, path)
  if not source.valid or source.index == nil:
    return
  let positions = initPositionIndex(source.text)
  let position =
    if methodName == "textDocument/prepareCallHierarchy":
      valueOrEmpty(params, "position")
    else:
      valueOrEmpty(item["selectionRange"], "start")
  let offset = offsetAt(positions, source.text, position)
  let target = hierarchyTargetAt(workspace, source, offset)
  if not target.supported:
    result.needsBootstrap = target.needsBootstrap
    return
  if methodName == "textDocument/prepareCallHierarchy":
    let hierarchyItem =
      callHierarchyItem(workspace, source, uriText, target.target, positions)
    if hierarchyItem != nil:
      result.value = newJArray()
      result.value.add hierarchyItem
    return

  let resolved =
    if methodName == "callHierarchy/incomingCalls":
      incomingCalls(workspace, source, offset)
    else:
      outgoingCalls(workspace, source, offset)
  if not resolved.supported:
    result.needsBootstrap = resolved.needsBootstrap
    return

  var groups: seq[HierarchyGroup] = @[]
  for relation in resolved.calls:
    let groupTarget =
      if methodName == "callHierarchy/incomingCalls":
        relation.caller
      else:
        relation.callee
    let callFile =
      if methodName == "callHierarchy/incomingCalls":
        relation.caller.fileId
      else:
        source.fileId
    let callSource =
      if callFile.value == source.fileId.value:
        source
      else:
        workspace.snapshotForFile(callFile)
    if not callSource.valid or callSource.index == nil or
        relation.callToken >= uint32(callSource.index.parsed.tokens.len):
      continue
    let callUri =
      if callFile.value == source.fileId.value:
        uriText
      elif callSource.uri.len > 0:
        callSource.uri
      else:
        fileUri(callSource.path)
    let callPositions = initPositionIndex(callSource.text)
    let location = referenceLocation(
      callUri,
      callSource,
      callSource.index.parsed.tokens[int(relation.callToken)],
      callPositions,
    )
    if location != nil:
      groups.addHierarchyGroup(groupTarget, location["range"])

  result.value = newJArray()
  for group in groups:
    let groupItem =
      callHierarchyItem(workspace, source, uriText, group.target, positions)
    if groupItem == nil:
      continue
    if methodName == "callHierarchy/incomingCalls":
      result.value.add %*{"from": groupItem, "fromRanges": group.ranges}
    else:
      result.value.add %*{"to": groupItem, "fromRanges": group.ranges}
