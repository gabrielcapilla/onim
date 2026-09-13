import ../features/organize
import ../semantic/worker
import ../session/ids
import ../session/workspace_models
import ./lsp_event_bridges
import ./semantic_key
import ./semantic_queue

var lspSemanticBridge*: Thread[void]
var lspSemanticBridgeStarted*: bool

proc startSemanticBridge*(): bool =
  if lspSemanticBridgeStarted:
    return true
  try:
    createThread(lspSemanticBridge, semanticEventBridge)
    lspSemanticBridgeStarted = true
    true
  except CatchableError:
    false

proc dispatchSemantic*(
    queued: var seq[SemanticRequest], pending: var SemanticKey
): bool =
  if pending.fileId.valid or queued.len == 0:
    return false
  let request = queued[0]
  pending = semanticKey(request)
  if not startSemanticWorker():
    pending = SemanticKey()
    return false
  if not submitSemantic(request):
    stopSemanticWorker()
    finishSemanticWorkerStop()
    pending = SemanticKey()
    return false
  if not startSemanticBridge():
    stopSemanticWorker()
    finishSemanticWorkerStop()
    pending = SemanticKey()
    return false
  queued.delete(0)
  true

proc enqueueSemantic*(
    snapshot: WorkspaceSnapshot,
    options: OrganizeOptions,
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
): bool =
  if not snapshot.valid:
    return false
  let request = SemanticRequest(
    kind: semanticOrganize,
    fileId: snapshot.fileId,
    path: snapshot.path,
    source: snapshot.text,
    contentGeneration: snapshot.contentGeneration,
    dependencyGeneration: snapshot.dependencyGeneration,
    configGeneration: snapshot.configGeneration,
    surfaceGeneration: snapshot.surfaceGeneration,
    useStdPrefix: options.useStdPrefix,
  )
  let key = semanticKey(request)
  if pending.fileId.valid and (
    (pending.workKind == semanticOrganize and sameSemanticGeneration(pending, key)) or
    sameSemanticKey(pending, key)
  ):
    return true
  queueSemantic(queued, request)
  if not pending.fileId.valid and not dispatchSemantic(queued, pending):
    removeQueued(queued, request.fileId)
    return false
  true

proc enqueueSemanticDiagnostics*(
    snapshot: WorkspaceSnapshot,
    options: OrganizeOptions,
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
): bool =
  if not snapshot.valid:
    return false
  let request = SemanticRequest(
    kind: semanticDiagnostics,
    fileId: snapshot.fileId,
    path: snapshot.path,
    source: snapshot.text,
    contentGeneration: snapshot.contentGeneration,
    dependencyGeneration: snapshot.dependencyGeneration,
    configGeneration: snapshot.configGeneration,
    surfaceGeneration: snapshot.surfaceGeneration,
    useStdPrefix: options.useStdPrefix,
  )
  let key = semanticKey(request)
  if pending.fileId.valid and pending.workKind == semanticOrganize and
      sameSemanticGeneration(pending, key):
    return true
  if pending.fileId.valid and sameSemanticKey(pending, key):
    return true
  queueSemantic(queued, request)
  if not pending.fileId.valid and not dispatchSemantic(queued, pending):
    removeQueued(queued, request.fileId)
    return false
  true
