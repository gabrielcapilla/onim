import ../features/organize
import ../semantic/worker
import ../session/ids
import ../session/workspace
import ./action_cache
import ./semantic_dispatch
import ./semantic_key
import ./semantic_queue

proc acceptSemantic*(
    value: SemanticResult,
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
) =
  if value.failed:
    if value.fileId.valid:
      removePending(pending, semanticKey(value))
      discard dispatchSemantic(queued, pending)
    else:
      pending = SemanticKey()
      queued.setLen(0)
    return
  if not value.fileId.valid:
    pending = SemanticKey()
    queued.setLen(0)
    return
  let key = semanticKey(value)
  removePending(pending, key)
  let snapshot = workspace.snapshotForFile(value.fileId)
  if snapshot.valid and
      sameSemanticKey(
        semanticKey(snapshot, OrganizeOptions(useStdPrefix: value.useStdPrefix)), key
      ):
    storeCachedAction(
      actionCache,
      value.fileId,
      CachedAction(
        contentGeneration: value.contentGeneration,
        dependencyGeneration: value.dependencyGeneration,
        configGeneration: value.configGeneration,
        surfaceGeneration: value.surfaceGeneration,
        useStdPrefix: value.useStdPrefix,
        edits: value.edits,
      ),
    )
  discard dispatchSemantic(queued, pending)
