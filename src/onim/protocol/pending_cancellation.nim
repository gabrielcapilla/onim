import std/json

import ../semantic/worker
import ../session/ids
import ./pending_code_actions
import ./pending_workspace
import ./semantic_key
import ./semantic_queue
import ./transport

proc sameRequestId*(left, right: JsonNode): bool =
  left != nil and right != nil and left.kind == right.kind and left == right

proc cancelPendingCodeAction*(
    pending: var seq[PendingCodeAction],
    queued: var seq[SemanticRequest],
    active: var SemanticKey,
    requestId: JsonNode,
): tuple[found: bool, stopWorker: bool] =
  for index, item in pending:
    if sameRequestId(item.id, requestId):
      let key = item.semantic
      pending.delete(index)
      sendError(item.id, -32800, "Request cancelled")
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

proc cancelPendingCodeActions*(pending: var seq[PendingCodeAction]) =
  for item in pending:
    sendError(item.id, -32800, "Request cancelled")
  pending.setLen(0)

proc cancelPendingWorkspaceRequest*(
    pending: var seq[PendingWorkspaceRequest], requestId: JsonNode
): bool =
  for index, item in pending:
    if sameRequestId(item.id, requestId):
      let id = item.id
      pending.delete(index)
      sendError(id, -32800, "Request cancelled")
      return true
  false

proc cancelPendingWorkspaceRequests*(pending: var seq[PendingWorkspaceRequest]) =
  for item in pending:
    sendError(item.id, -32800, "Request cancelled")
  pending.setLen(0)
