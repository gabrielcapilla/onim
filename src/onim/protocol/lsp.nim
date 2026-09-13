import std/[atomics, json, monotimes]
import std/os except FileId

import ../features/organize
import ../semantic/worker
import ../session/bootstrap_worker
import ../session/ids
import ../session/paths
import ../session/workspace
import ../index/source_index
import ../stdlib/map
import ../stdlib/map_runtime
import ./call_hierarchy
import ./location_responses
import ./completion_response
import ./document_changes
import ./initialization
import ./semantic_key
import ./action_cache
import ./semantic_queue
import ./action_indexing
import ./pending_workspace
import ./pending_code_actions
import ./pending_cancellation
import ./bootstrap_runtime
import ./message_parsing
import ./process_lifetime
import ./tracing
import ./diagnostic_publish
import ./semantic_tokens_response
import ./rename
import ./navigation
import ./text_features
import ./transport
import ./uris
import ./validation
import ./lsp_events as lspEventTypes
import ./lsp_event_bridges
import ./semantic_dispatch
import ./semantic_event_handling
import ./code_action_flow

var lspInputReader: Thread[void]
var lspBootstrapBridge: Thread[void]
var lspInputReaderStarted = false
var lspBootstrapBridgeStarted = false
var lspTraceEnabled = false

proc sendResponseEffects(effects: openArray[ResponseEffect]) =
  for effect in effects:
    sendResponse(effect.id, effect.result)

proc cancelPendingWorkspaceForUri(
    pending: var seq[PendingWorkspaceRequest], uri: string
) =
  for requestId in cancelPendingWorkspaceRequestsForUri(pending, uri):
    sendError(requestId, -32801, "Content modified")

proc runLsp*() =
  when defined(linux):
    bindToParentProcess()
  lspTraceEnabled = getEnv("ONIM_TRACE_LSP").len > 0
  let workspace = initWorkspace()
  var stdlib = emptyStdlibMap()
  var actionCache: seq[CachedAction] = @[]
  var pending: SemanticKey
  var queued: seq[SemanticRequest] = @[]
  var pendingWorkspace: seq[PendingWorkspaceRequest] = @[]
  var pendingCodeActions: seq[PendingCodeAction] = @[]
  var bootstrap: BootstrapRuntime
  var options = defaultOrganizeOptions()
  var opinionatedHints = false
  var insertReplaceSupport = false
  var snippetSupport = false
  var initializeAccepted = false
  var shutdownRequested = false
  var exitRequested = false

  lspEvents.open()
  lspInputReaderStarted = false
  lspBootstrapBridgeStarted = false
  lspSemanticBridgeStarted = false
  if startBootstrapWorker():
    createThread(lspBootstrapBridge, bootstrapEventBridge)
    lspBootstrapBridgeStarted = true
  createThread(lspInputReader, readInputEvents)
  lspInputReaderStarted = true

  while true:
    let event = lspEvents.recv()
    if initializeAccepted:
      let wasComplete = stdlib.surfaceIsComplete
      if pollStdlibMap(stdlib) == stdlibRuntimeReady and not wasComplete:
        actionCache.setLen(0)
    if event.kind == lspEndEvent:
      break
    if event.kind == lspBootstrapEvent:
      if shutdownRequested:
        continue
      let bootstrapResult = decodeBootstrapResult(event.payload)
      let accepted = handleBootstrapEvent(
        bootstrap, workspace, pendingWorkspace, stdlib, event.payload, lspTraceEnabled,
        options.useStdPrefix, insertReplaceSupport, snippetSupport,
      )
      if bootstrapResult.kind != bootstrapStopped:
        for fileId in workspace.openDocumentIds:
          let snapshot = workspace.snapshotForFile(fileId)
          discard enqueueSemanticDiagnostics(snapshot, options, pending, queued)
        if accepted and not bootstrap.active:
          resolveBootstrapCodeActions(
            pendingCodeActions, workspace, stdlib, actionCache, pending, queued, true
          )
        elif not accepted and not bootstrap.active:
          var retryBootstrap = false
          for item in pendingCodeActions:
            if item.waitingForBootstrap:
              retryBootstrap = true
              break
          if bootstrapResult.kind == bootstrapComplete and retryBootstrap:
            if not scheduleBootstrap(bootstrap, workspace):
              resolveBootstrapCodeActions(
                pendingCodeActions, workspace, stdlib, actionCache, pending, queued,
                false,
              )
          else:
            resolveBootstrapCodeActions(
              pendingCodeActions, workspace, stdlib, actionCache, pending, queued, false
            )
      continue
    if event.kind == lspSemanticEvent:
      let semantic = decodeSemanticResult(event.payload)
      var responseEffects: seq[ResponseEffect] = @[]
      let stopped =
        if semantic.workKind == semanticDiagnostics:
          handleSemanticDiagnostics(
            semantic, workspace, stdlib, lspTraceEnabled, pending, queued
          )
        else:
          discard
            publishSemanticDiagnostics(semantic, workspace, stdlib, lspTraceEnabled)
          handleSemanticEvent(
            event.payload, workspace, actionCache, pending, queued, pendingCodeActions,
            responseEffects,
          )
      sendResponseEffects(responseEffects)
      if stopped:
        lspSemanticStopRequested.store(true)
        stopSemanticWorker()
        if lspSemanticBridgeStarted:
          lspSemanticBridge.joinThread()
          lspSemanticBridgeStarted = false
        finishSemanticWorkerStop()
        lspSemanticStopRequested.store(false)
      continue

    let message = parseMessage(event.payload)
    if message == nil:
      sendError(newJNull(), -32700, "Parse error")
      continue
    if not validRequestEnvelope(message):
      sendError(newJNull(), -32600, "Invalid Request")
      continue
    let methodName = message["method"].getStr
    let hasId = message.hasKey("id")
    let id =
      if hasId:
        message["id"]
      else:
        newJNull()
    let params =
      if message.hasKey("params"):
        message["params"]
      else:
        newJObject()
    if not validMethodForm(methodName, hasId):
      if hasId:
        sendError(id, -32600, "Invalid Request")
      continue
    if shutdownRequested:
      if methodName == "exit":
        if validMethodParams(methodName, params):
          exitRequested = true
          break
        continue
      if hasId:
        sendError(id, -32600, "Invalid Request")
      continue
    if methodName == "exit":
      if validMethodParams(methodName, params):
        exitRequested = true
        break
      continue
    if methodName == "initialize":
      if initializeAccepted:
        sendError(id, -32600, "Invalid Request")
        continue
      if not validMethodParams(methodName, params):
        sendError(id, -32602, "Invalid params")
        continue
      initializeAccepted = true
      let root = initializeRoot(params)
      if root.len > 0 and not broadWorkspaceRoot(root):
        discard workspace.prepareWorkspace(root)
      options.useStdPrefix = boolOption(params, "useStdPrefix", true)
      opinionatedHints = boolOption(params, "opinionatedHints", false)
      insertReplaceSupport = clientSupportsInsertReplace(params)
      snippetSupport = clientSupportsSnippets(params)
      discard startStdlibMap(
        if root.len > 0:
          root
        else:
          getCurrentDir(),
        stdlib,
      )
      sendResponse(id, initializeResult())
      discard scheduleBootstrap(bootstrap, workspace)
      continue
    if not initializeAccepted:
      if hasId:
        sendError(id, -32002, "Server not initialized")
      continue
    if not validMethodParams(methodName, params):
      if hasId:
        sendError(id, -32602, "Invalid params")
      continue
    case methodName
    of "initialized":
      discard
    of "shutdown":
      shutdownRequested = true
      for requestId in cancelPendingCodeActions(pendingCodeActions):
        sendError(requestId, -32800, "Request cancelled")
      for requestId in cancelPendingWorkspaceRequests(pendingWorkspace):
        sendError(requestId, -32800, "Request cancelled")
      pending = SemanticKey()
      queued.setLen(0)
      sendResponse(id, newJNull())
    of "exit":
      discard
    of "textDocument/didOpen":
      let update = applyDidOpen(workspace, params)
      if update.accepted:
        sendResponseEffects(
          finishPendingCodeActionsForUri(pendingCodeActions, update.uri)
        )
        publishNativeDiagnostics(
          workspace, update.current, stdlib, diagnosticOpen, lspTraceEnabled
        )
        discard
          cacheIndexedAction(workspace, update.current, options, stdlib, actionCache)
        discard enqueueSemanticDiagnostics(update.current, options, pending, queued)
        discard scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didChange":
      let update = applyDidChange(workspace, params)
      if update.accepted and update.contentChanged:
        cancelPendingWorkspaceForUri(pendingWorkspace, update.uri)
        sendResponseEffects(
          finishPendingCodeActionsForUri(pendingCodeActions, update.uri)
        )
        publishNativeDiagnostics(
          workspace, update.current, stdlib, diagnosticEdit, lspTraceEnabled
        )
        discard
          cacheIndexedAction(workspace, update.current, options, stdlib, actionCache)
        discard enqueueSemanticDiagnostics(update.current, options, pending, queued)
        discard scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didClose":
      let textDocument = params["textDocument"]
      let uriText = textDocument["uri"].getStr
      let path = uriToPath(uriText)
      if workspace.isOpenDocument(path):
        let fileId = workspace.fileIdForPath(path)
        cancelPendingWorkspaceForUri(pendingWorkspace, uriText)
        sendResponseEffects(finishPendingCodeActionsForUri(pendingCodeActions, uriText))
        removeQueued(queued, fileId)
        workspace.closeDocument(uriText, path)
        clearCachedAction(actionCache, fileId)
        clearNativeDiagnostics(uriText, lspTraceEnabled)
        discard scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didSave":
      let textDocument = params["textDocument"]
      let uriText = textDocument["uri"].getStr
      let path = uriToPath(uriText)
      if workspace.isOpenDocument(path) and params.hasKey("text"):
        let before = workspace.snapshotForFile(workspace.fileIdForPath(path))
        if workspace.changeDocument(uriText, path, params["text"].getStr, -1):
          let snapshot = workspace.snapshotForDocument(uriText, path)
          if before.contentGeneration.value != snapshot.contentGeneration.value:
            cancelPendingWorkspaceForUri(pendingWorkspace, uriText)
            sendResponseEffects(
              finishPendingCodeActionsForUri(pendingCodeActions, uriText)
            )
            publishNativeDiagnostics(
              workspace, snapshot, stdlib, diagnosticEdit, lspTraceEnabled
            )
            discard
              cacheIndexedAction(workspace, snapshot, options, stdlib, actionCache)
            discard enqueueSemanticDiagnostics(snapshot, options, pending, queued)
            discard scheduleBootstrap(bootstrap, workspace)
    of "workspace/didChangeWatchedFiles":
      let changes = params["changes"]
      if changes.len > 0:
        for change in changes.items:
          let path = uriToPath(change["uri"].getStr)
          workspace.fileChanged(path, change["type"].getInt == 3)
        discard scheduleBootstrap(bootstrap, workspace)
    of "textDocument/definition":
      if hasId:
        var response = definitionResponse(params, workspace)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingDefinition, id: id, params: params
            )
          else:
            discard workspace.bootstrapWorkspace()
            response = definitionResponse(params, workspace)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/typeDefinition":
      if hasId:
        var response = typeDefinitionResponse(params, workspace)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingTypeDefinition, id: id, params: params
            )
          else:
            discard workspace.bootstrapWorkspace()
            response = typeDefinitionResponse(params, workspace)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/implementation":
      if hasId:
        var response = implementationResponse(params, workspace)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingImplementation, id: id, params: params
            )
          else:
            discard workspace.bootstrapWorkspace()
            response = implementationResponse(params, workspace)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls",
        "callHierarchy/outgoingCalls":
      if hasId:
        let pendingKind =
          case methodName
          of "textDocument/prepareCallHierarchy": pendingPrepareCallHierarchy
          of "callHierarchy/incomingCalls": pendingIncomingCalls
          else: pendingOutgoingCalls
        var response = callHierarchyResponse(methodName, params, workspace)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingKind, id: id, params: params
            )
          else:
            discard workspace.bootstrapWorkspace()
            response = callHierarchyResponse(methodName, params, workspace)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/references":
      if hasId:
        let response = referencesResponse(params, workspace)
        if response.needsBootstrap:
          pendingWorkspace.add PendingWorkspaceRequest(
            kind: pendingReferences, id: id, params: params
          )
          if not bootstrap.active:
            if not scheduleBootstrap(bootstrap, workspace):
              pendingWorkspace.setLen(pendingWorkspace.len - 1)
              sendResponse(id, newJNull())
        else:
          sendResponse(id, response.value)
    of "textDocument/prepareRename":
      if hasId:
        let response = prepareRenameResponse(params, workspace)
        if response.needsBootstrap:
          pendingWorkspace.add PendingWorkspaceRequest(
            kind: pendingPrepareRename, id: id, params: params
          )
          if not bootstrap.active:
            if not scheduleBootstrap(bootstrap, workspace):
              pendingWorkspace.setLen(pendingWorkspace.len - 1)
              sendResponse(id, newJNull())
        else:
          sendResponse(id, response.value)
    of "textDocument/hover":
      if hasId:
        var response = hoverResponse(params, workspace, stdlib)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingHover, id: id, params: params
            )
          else:
            discard workspace.bootstrapWorkspace()
            response = hoverResponse(params, workspace, stdlib)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/rename":
      if hasId:
        let response = renameResponse(params, workspace)
        if response.needsBootstrap:
          pendingWorkspace.add PendingWorkspaceRequest(
            kind: pendingRename, id: id, params: params
          )
          if not bootstrap.active:
            if not scheduleBootstrap(bootstrap, workspace):
              pendingWorkspace.setLen(pendingWorkspace.len - 1)
              sendResponse(id, newJNull())
        else:
          sendResponse(id, response.value)
    of "textDocument/completion":
      if hasId:
        let response = completionResponse(
          params, workspace, stdlib, options.useStdPrefix, insertReplaceSupport,
          snippetSupport,
        )
        if response.needsBootstrap:
          pendingWorkspace.add PendingWorkspaceRequest(
            kind: pendingCompletion, id: id, params: params
          )
          if not bootstrap.active:
            if not scheduleBootstrap(bootstrap, workspace):
              pendingWorkspace.setLen(pendingWorkspace.len - 1)
              sendError(id, -32603, "Workspace bootstrap could not be restarted")
        else:
          sendResponse(id, response.value)
    of "textDocument/inlayHint":
      if hasId:
        sendResponse(id, inlayHints(params, workspace, opinionatedHints))
    of "textDocument/documentSymbol":
      if hasId:
        sendResponse(id, documentSymbols(params, workspace))
    of "textDocument/documentLink":
      if hasId:
        var response = documentLinks(params, workspace)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingDocumentLink, id: id, params: params
            )
            if not scheduleBootstrap(bootstrap, workspace):
              pendingWorkspace.setLen(pendingWorkspace.len - 1)
              sendError(id, -32603, "Workspace bootstrap could not be restarted")
          else:
            discard workspace.bootstrapWorkspace()
            response = documentLinks(params, workspace)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/documentHighlight":
      if hasId:
        sendResponse(id, documentHighlights(params, workspace))
    of "textDocument/foldingRange":
      if hasId:
        sendResponse(id, foldingRanges(params, workspace))
    of "textDocument/selectionRange":
      if hasId:
        sendResponse(id, selectionRanges(params, workspace))
    of "textDocument/signatureHelp":
      if hasId:
        var response = signatureHelpResponse(params, workspace, stdlib)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingSignatureHelp, id: id, params: params
            )
          else:
            discard workspace.bootstrapWorkspace()
            response = signatureHelpResponse(params, workspace, stdlib)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/semanticTokens/full":
      if hasId:
        sendResponse(id, semanticTokensResponse(params, workspace))
    of "textDocument/semanticTokens/range":
      if hasId:
        sendResponse(id, semanticTokensRangeResponse(params, workspace))
    of "workspace/symbol":
      if hasId:
        if workspace.bootstrapPending:
          if bootstrap.active:
            pendingWorkspace.add PendingWorkspaceRequest(
              kind: pendingWorkspaceSymbol, id: id, params: params
            )
          else:
            discard workspace.bootstrapWorkspace()
            sendResponse(id, workspaceSymbols(params, workspace))
        else:
          sendResponse(id, workspaceSymbols(params, workspace))
    of "$/cancelRequest":
      let requestId = params["id"]
      let cancellation =
        cancelPendingCodeAction(pendingCodeActions, queued, pending, requestId)
      if cancellation.found:
        sendError(cancellation.id, -32800, "Request cancelled")
      if cancellation.stopWorker:
        lspSemanticStopRequested.store(true, moRelaxed)
        discard interruptSemanticWorker()
        stopSemanticWorker()
        if lspSemanticBridgeStarted:
          lspSemanticBridge.joinThread()
          lspSemanticBridgeStarted = false
        finishSemanticWorkerStop()
        lspSemanticStopRequested.store(false, moRelaxed)
      if not cancellation.found:
        let workspaceCancellation =
          cancelPendingWorkspaceRequest(pendingWorkspace, requestId)
        if workspaceCancellation.found:
          sendError(workspaceCancellation.id, -32800, "Request cancelled")
    of "textDocument/codeAction":
      if hasId:
        let startedAt =
          if lspTraceEnabled:
            getMonoTime()
          else:
            MonoTime()
        let outcome = codeActionOutcome(
          params, workspace, stdlib, actionCache, pending, queued, options
        )
        traceLspRequest(
          lspTraceEnabled,
          lspSemanticBridgeStarted,
          "codeAction",
          id,
          startedAt,
          outcome.key,
          if outcome.deferred:
            "deferred"
          else:
            "ready edits=" & $outcome.response.len & " uriHash=" &
              $contentFingerprint(outcome.uri),
        )
        if outcome.key.fileId.valid:
          sendResponseEffects(
            finishPendingCodeActionsForUri(pendingCodeActions, outcome.uri)
          )
        if outcome.deferred:
          pendingCodeActions.add PendingCodeAction(
            id: id,
            semantic: outcome.key,
            uri: outcome.uri,
            waitingForBootstrap: outcome.waitingForBootstrap,
          )
        else:
          sendResponse(id, outcome.response)
    else:
      if hasId:
        sendError(id, -32601, "Method not found")
  if exitRequested:
    cancelBootstrap(high(uint64))
  lspSemanticStopRequested.store(true)
  stopSemanticWorker()
  if lspSemanticBridgeStarted:
    lspSemanticBridge.joinThread()
    lspSemanticBridgeStarted = false
  finishSemanticWorkerStop()
  lspSemanticStopRequested.store(false)
  if exitRequested:
    stopStdlibMapGeneration()
    terminateProcessNow(if shutdownRequested: 0 else: 1)
  if lspBootstrapBridgeStarted:
    stopBootstrapProducer()
    lspBootstrapBridge.joinThread()
    lspBootstrapBridgeStarted = false
    finishBootstrapWorkerStop()
  else:
    stopBootstrapWorker()
  if lspInputReaderStarted:
    lspInputReader.joinThread()
    lspInputReaderStarted = false
  lspEvents.close()
  if exitRequested:
    quit(if shutdownRequested: 0 else: 1)
