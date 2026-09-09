import std/[json, strutils]

import ../features/organize
import ../features/organize_edits
import ../semantic/worker
import ../session/workspace
import ../stdlib/map
import ./action_cache
import ./action_indexing
import ./code_action_options
import ./edits
import ./pending_code_actions
import ./semantic_dispatch
import ./semantic_key
import ./transport
import ./uris
import ./validation

proc codeActionOutcome*(
    params: JsonNode,
    workspace: Workspace,
    stdlib: var StdlibMap,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
    options: OrganizeOptions,
): tuple[
  response: JsonNode,
  deferred: bool,
  waitingForBootstrap: bool,
  key: SemanticKey,
  uri: string,
] =
  result.response = newJArray()
  if not supportsOrganize(params):
    return
  if not validTextDocumentParams(params):
    return
  let uriText = params["textDocument"]["uri"].getStr
  let path = uriToPath(uriText)
  if path.toLowerAscii.endsWith(".nimble") or path.toLowerAscii.endsWith(".cfg"):
    return
  let snapshot = workspace.snapshotForDocument(uriText, path)
  if not snapshot.valid:
    return
  result.uri = uriText
  result.key = semanticKey(snapshot, options)
  let cacheKey = snapshot.fileId
  var edits: seq[ImportEdit] = @[]
  var cacheHit = false
  if hasCachedAction(actionCache, cacheKey):
    let cached = cachedActionFor(actionCache, cacheKey)
    if actionIsCurrent(cached, snapshot, options):
      edits = cached.edits
      cacheHit = true
  if not cacheHit:
    let indexed = cacheIndexedAction(workspace, snapshot, options, stdlib, actionCache)
    if indexed.handled:
      edits = indexed.edits
    else:
      if bootstrapPending(workspace):
        result.deferred = true
        result.waitingForBootstrap = true
        result.uri = uriText
        return
      if enqueueSemantic(snapshot, options, pending, queued):
        result.deferred = true
        result.uri = uriText
        return
  result.response = renderCodeActions(uriText, snapshot.text, edits)

proc resolveBootstrapCodeActions*(
    pendingCodeActions: var seq[PendingCodeAction],
    workspace: Workspace,
    stdlib: var StdlibMap,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
    retry: bool,
) =
  var remaining: seq[PendingCodeAction] = @[]
  for item in pendingCodeActions:
    if not item.waitingForBootstrap:
      remaining.add item
      continue
    if not retry:
      sendResponse(item.id, newJArray())
      continue
    let snapshot = workspace.snapshotForFile(item.semantic.fileId)
    if not snapshot.valid:
      sendResponse(item.id, newJArray())
      continue
    let options = OrganizeOptions(useStdPrefix: item.semantic.useStdPrefix)
    let indexed = cacheIndexedAction(workspace, snapshot, options, stdlib, actionCache)
    if indexed.handled:
      sendResponse(item.id, renderCodeActions(item.uri, snapshot.text, indexed.edits))
      continue
    if enqueueSemantic(snapshot, options, pending, queued):
      var resumed = item
      resumed.semantic = semanticKey(snapshot, options)
      resumed.waitingForBootstrap = false
      remaining.add resumed
    else:
      sendResponse(item.id, newJArray())
  pendingCodeActions = remaining
  if retry:
    discard dispatchSemantic(queued, pending)
