import std/json

import ../semantic/worker
import ../session/ids
import ./pending_code_actions
import ./pending_workspace
import ./semantic_key
import ./semantic_queue

type CancelOutcome* = object
  found*: bool
  stopWorker*: bool
  id*: JsonNode

proc sameRequestId*(left, right: JsonNode): bool =
  left != nil and right != nil and left.kind == right.kind and left == right

proc cancelPendingCodeAction*(
    pending: var seq[PendingCodeAction],
    queued: var seq[SemanticRequest],
    active: var SemanticKey,
    requestId: JsonNode,
): CancelOutcome =
  for index, item in pending:
    if sameRequestId(item.id, requestId):
      let key = item.semantic
      pending.delete(index)
      result.id = item.id
      for other in pending:
        if sameSemanticKey(other.semantic, key):
          result.found = true
          return
      removeQueued(queued, key)
      if active.fileId.valid and sameSemanticKey(active, key) and queued.len == 0:
        active = SemanticKey()
        result.stopWorker = true
      result.found = true
      return

proc cancelPendingCodeActions*(pending: var seq[PendingCodeAction]): seq[JsonNode] =
  for item in pending:
    result.add item.id
  pending.setLen(0)

proc cancelPendingWorkspaceRequest*(
    pending: var seq[PendingWorkspaceRequest], requestId: JsonNode
): CancelOutcome =
  for index, item in pending:
    if sameRequestId(item.id, requestId):
      pending.delete(index)
      result.found = true
      result.id = item.id
      return

proc cancelPendingWorkspaceRequests*(
    pending: var seq[PendingWorkspaceRequest]
): seq[JsonNode] =
  for item in pending:
    result.add item.id
  pending.setLen(0)

proc pendingWorkspaceRequestUri(item: PendingWorkspaceRequest): string =
  if item.kind == pendingWorkspaceSymbol or item.params == nil or
      item.params.kind != JObject:
    return
  let field =
    case item.kind
    of pendingIncomingCalls, pendingOutgoingCalls: "item"
    else: "textDocument"
  if not item.params.hasKey(field) or item.params[field].kind != JObject:
    return
  let value = item.params[field]
  if value.hasKey("uri") and value["uri"].kind == JString:
    result = value["uri"].getStr

proc cancelPendingWorkspaceRequestsForUri*(
    pending: var seq[PendingWorkspaceRequest], uri: string
): seq[JsonNode] =
  var writeIndex = 0
  for item in pending:
    if pendingWorkspaceRequestUri(item) == uri:
      result.add item.id
    else:
      pending[writeIndex] = item
      inc writeIndex
  pending.setLen(writeIndex)
