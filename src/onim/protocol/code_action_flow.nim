import std/[json, strutils]

import ../features/organize
import ../features/organize_edits
import ../features/typo
import ../semantic/worker
import ../session/workspace
import ../session/workspace_models
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
import ./positions
import ./validation

proc typoCodeActions(
    params: JsonNode,
    workspace: Workspace,
    snapshot: WorkspaceSnapshot,
    stdlib: StdlibMap,
): JsonNode =
  result = newJArray()
  let context = valueOrEmpty(params, "context")
  if context.kind != JObject or not context.hasKey("diagnostics") or
      context["diagnostics"].kind != JArray:
    return
  let uriText = valueOrEmpty(params, "textDocument")["uri"].getStr
  let positions = initPositionIndex(snapshot.text)
  for diagnostic in context["diagnostics"].items:
    if diagnostic == nil or diagnostic.kind != JObject or not diagnostic.hasKey("code") or
        diagnostic["code"].kind != JString or diagnostic["code"].getStr != "onim.typo" or
        not diagnostic.hasKey("range") or diagnostic["range"].kind != JObject or
        not diagnostic["range"].hasKey("start") or not diagnostic["range"].hasKey("end") or
        not diagnostic.hasKey("data") or diagnostic["data"].kind != JObject:
      continue
    let data = diagnostic["data"]
    if not data.hasKey("replacement") or data["replacement"].kind != JString:
      continue
    let start = offsetAt(positions, snapshot.text, diagnostic["range"]["start"])
    let finish = offsetAt(positions, snapshot.text, diagnostic["range"]["end"])
    if start < 0 or finish <= start:
      continue
    let match = typoAt(workspace, snapshot, finish, stdlib)
    if match.startOffset != start or match.endOffset != finish or
        match.suggestion != data["replacement"].getStr:
      continue
    result.add %*{
      "title": "Replace `" & match.name & "` with `" & match.suggestion & "`",
      "kind": "quickfix",
      "diagnostics": [diagnostic],
      "edit": {
        "changes":
          {uriText: [{"range": diagnostic["range"], "newText": match.suggestion}]}
      },
    }

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
  if not supportsOrganize(params) and not supportsQuickFix(params):
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
  var quickFixes = newJArray()
  if supportsQuickFix(params):
    quickFixes = typoCodeActions(params, workspace, snapshot, stdlib)
  if not supportsOrganize(params):
    result.response = quickFixes
    return
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
        if quickFixes.len > 0:
          result.response = quickFixes
          return
        result.deferred = true
        result.waitingForBootstrap = true
        result.uri = uriText
        return
      if enqueueSemantic(snapshot, options, pending, queued):
        if quickFixes.len > 0:
          result.response = quickFixes
          return
        result.deferred = true
        result.uri = uriText
        return
  result.response = renderCodeActions(uriText, snapshot.text, edits)
  for action in quickFixes.items:
    result.response.add action

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
