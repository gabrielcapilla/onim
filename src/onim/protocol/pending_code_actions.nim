import std/json

import ../features/organize
import ../semantic/worker
import ../session/ids
import ../session/workspace
import ./action_cache
import ./action_indexing
import ./edits
import ./semantic_key
import ./semantic_queue
import ./transport

type PendingCodeAction* = object
  id*: JsonNode
  semantic*: SemanticKey
  uri*: string
  waitingForBootstrap*: bool

proc finishPendingCodeActionsForUri*(pending: var seq[PendingCodeAction], uri: string) =
  var completed: seq[PendingCodeAction] = @[]
  var writeIndex = 0
  for item in pending:
    if item.uri == uri:
      completed.add item
    else:
      pending[writeIndex] = item
      inc writeIndex
  pending.setLen(writeIndex)
  for item in completed:
    sendResponse(item.id, newJArray())

proc finishPendingCodeActions*(
    pending: var seq[PendingCodeAction],
    workspace: Workspace,
    actionCache: seq[CachedAction],
    value: SemanticResult,
): bool =
  let terminal = value.failed and not value.fileId.valid
  let key = semanticKey(value)
  var completed: seq[PendingCodeAction] = @[]
  var writeIndex = 0
  for item in pending:
    if terminal or sameSemanticKey(item.semantic, key):
      completed.add item
    else:
      pending[writeIndex] = item
      inc writeIndex
  pending.setLen(writeIndex)
  for item in completed:
    if not terminal:
      let snapshot = workspace.snapshotForFile(item.semantic.fileId)
      if snapshot.valid and hasCachedAction(actionCache, item.semantic.fileId) and
          actionIsCurrent(
            cachedActionFor(actionCache, item.semantic.fileId),
            snapshot,
            OrganizeOptions(useStdPrefix: item.semantic.useStdPrefix),
          ):
        sendResponse(
          item.id,
          renderCodeActions(
            item.uri,
            snapshot.text,
            cachedActionFor(actionCache, item.semantic.fileId).edits,
          ),
        )
        continue
    sendResponse(item.id, newJArray())
  terminal
