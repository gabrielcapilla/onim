import ../features/organize
import ../semantic/compiler_api
import ../semantic/worker
import ../session/ids
import ../session/workspace
import ../session/workspace_models
import ../stdlib/map
import ./action_cache
import ./diagnostic_publish
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

proc publishSemanticDiagnostics*(
    value: SemanticResult, workspace: Workspace, stdlib: StdlibMap, traceEnabled: bool
): bool =
  if value.failed or not value.fileId.valid or value.diagnostics.len == 0:
    return false
  var unused: seq[CompilerDiagnostic] = @[]
  for diagnostic in value.diagnostics:
    if diagnostic.isUnusedDeclaration:
      unused.add diagnostic
  if unused.len == 0:
    return false
  let snapshot = workspace.snapshotForFile(value.fileId)
  if not snapshot.valid or
      not sameSemanticGeneration(
        semanticKey(snapshot, OrganizeOptions(useStdPrefix: value.useStdPrefix)),
        semanticKey(value),
      ):
    return false
  publishNativeDiagnostics(
    workspace, snapshot, stdlib, diagnosticEdit, traceEnabled, unused
  )
  true

proc handleSemanticDiagnostics*(
    value: SemanticResult,
    workspace: Workspace,
    stdlib: StdlibMap,
    traceEnabled: bool,
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
): bool =
  let key = semanticKey(value)
  removePending(pending, key)
  discard publishSemanticDiagnostics(value, workspace, stdlib, traceEnabled)
  discard dispatchSemantic(queued, pending)
  result = false

proc handleSemanticEvent*(
    payload: string,
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
    pendingCodeActions: var seq[PendingCodeAction],
    responses: var seq[ResponseEffect],
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
    responses =
      finishPendingCodeActions(pendingCodeActions, workspace, actionCache, value)
  result = not pending.fileId.valid and queued.len == 0
