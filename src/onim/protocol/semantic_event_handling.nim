import ../features/organize
import ../semantic/worker
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ./action_cache
import ./pending_code_actions
import ./semantic_dispatch
import ./semantic_key
import ./semantic_queue
import ./semantic_results

proc refreshPendingCodeActions*(
    pendingCodeActions: var seq[PendingCodeAction],
    workspace: Workspace,
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
    stale: SemanticKey,
) =
  for index in 0 ..< pendingCodeActions.len:
    if not sameSemanticKey(pendingCodeActions[index].semantic, stale):
      continue
    let options =
      OrganizeOptions(useStdPrefix: pendingCodeActions[index].semantic.useStdPrefix)
    let snapshot = workspace.snapshotForFile(pendingCodeActions[index].semantic.fileId)
    if not snapshot.valid:
      continue
    if enqueueSemantic(snapshot, options, pending, queued):
      pendingCodeActions[index].semantic = semanticKey(snapshot, options)
  discard dispatchSemantic(queued, pending)

proc handleSemanticEvent*(
    payload: string,
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
    pendingCodeActions: var seq[PendingCodeAction],
): bool =
  let value = decodeSemanticResult(payload)
  let valueKey = semanticKey(value)
  let snapshot =
    if value.fileId.valid:
      workspace.snapshotForFile(value.fileId)
    else:
      WorkspaceSnapshot()
  let stale =
    value.fileId.valid and not value.failed and snapshot.valid and
    not sameSemanticKey(
      semanticKey(snapshot, OrganizeOptions(useStdPrefix: value.useStdPrefix)), valueKey
    )
  acceptSemantic(value, workspace, actionCache, pending, queued)
  if stale:
    refreshPendingCodeActions(pendingCodeActions, workspace, pending, queued, valueKey)
  else:
    discard finishPendingCodeActions(pendingCodeActions, workspace, actionCache, value)
  result = not pending.fileId.valid and queued.len == 0
