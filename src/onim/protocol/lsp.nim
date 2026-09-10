import std/[atomics, json, monotimes, strutils, times]
import std/os except FileId

import ../features/completion
import ../features/definition
import ../features/hover
import ../features/hierarchy
import ../features/inlay
import ../features/organize
import ../features/rename
import ../features/signature
import ../features/semantic_tokens
import ../semantic/worker
import ../session/bootstrap_worker
import ../session/ids
import ../session/module_catalog
import ../session/paths
import ../session/workspace
import ../index/source_index
import ../index/surfaces
import ../index/symbols
import ../index/types
import ../stdlib/map
import ../stdlib/map_runtime
import ../syntax/tokens
import ../syntax/imports
import ../syntax/parser
import ./positions
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
import ./code_action_options
import ./process_lifetime
import ./tracing
import ./diagnostic_publish
import ./semantic_tokens_response
import ./rename
import ./navigation
import ./text_features
import ./edits
import ./transport
import ./uris
import ./validation
import ./lsp_events as lspEventTypes
import ./lsp_event_bridges
import ./semantic_dispatch
import ./semantic_results
import ./semantic_event_handling
import ./code_action_flow

var lspInputReader: Thread[void]
var lspBootstrapBridge: Thread[void]
var lspInputReaderStarted = false
var lspBootstrapBridgeStarted = false
var lspTraceEnabled = false

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
        bootstrap, workspace, pendingWorkspace, stdlib, event.payload, lspTraceEnabled
      )
      if bootstrapResult.kind != bootstrapStopped:
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
      if handleSemanticEvent(
        event.payload, workspace, actionCache, pending, queued, pendingCodeActions
      ):
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
      cancelPendingCodeActions(pendingCodeActions)
      cancelPendingWorkspaceRequests(pendingWorkspace)
      pending = SemanticKey()
      queued.setLen(0)
      sendResponse(id, newJNull())
    of "exit":
      discard
    of "textDocument/didOpen":
      let textDocument = params["textDocument"]
      let uriText = textDocument["uri"].getStr
      let path = uriToPath(uriText)
      discard workspace.prepareWorkspaceForDocument(path)
      if not workspace.isOpenDocument(path):
        let fileId = workspace.openDocument(
          uriText, path, textDocument["text"].getStr, textDocument["version"].getInt
        )
        if fileId.valid:
          let snapshot = workspace.snapshotForDocument(uriText, path)
          if snapshot.valid:
            finishPendingCodeActionsForUri(pendingCodeActions, uriText)
            publishNativeDiagnostics(
              workspace, snapshot, stdlib, diagnosticOpen, lspTraceEnabled
            )
            if not cacheIndexedAction(workspace, snapshot, options, stdlib, actionCache).handled and
                not bootstrapPending(workspace):
              discard enqueueSemantic(snapshot, options, pending, queued)
            discard scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didChange":
      let change = parseDocumentChange(params)
      if change.valid:
        let path = uriToPath(change.uri)
        if workspace.isOpenDocument(path):
          let before = workspace.snapshotForFile(workspace.fileIdForPath(path))
          let materialized = materializeDocumentChange(change, before.text)
          if materialized.valid and
              workspace.changeDocument(
                change.uri, path, materialized.text, change.version
              ):
            let snapshot = workspace.snapshotForDocument(change.uri, path)
            if before.contentGeneration.value != snapshot.contentGeneration.value:
              finishPendingCodeActionsForUri(pendingCodeActions, change.uri)
              publishNativeDiagnostics(
                workspace, snapshot, stdlib, diagnosticEdit, lspTraceEnabled
              )
              if not cacheIndexedAction(
                workspace, snapshot, options, stdlib, actionCache
              ).handled and not bootstrapPending(workspace):
                discard enqueueSemantic(snapshot, options, pending, queued)
              discard scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didClose":
      let textDocument = params["textDocument"]
      let uriText = textDocument["uri"].getStr
      let path = uriToPath(uriText)
      if workspace.isOpenDocument(path):
        let fileId = workspace.fileIdForPath(path)
        finishPendingCodeActionsForUri(pendingCodeActions, uriText)
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
            finishPendingCodeActionsForUri(pendingCodeActions, uriText)
            publishNativeDiagnostics(
              workspace, snapshot, stdlib, diagnosticEdit, lspTraceEnabled
            )
            if not cacheIndexedAction(workspace, snapshot, options, stdlib, actionCache).handled and
                not bootstrapPending(workspace):
              discard enqueueSemantic(snapshot, options, pending, queued)
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
        sendResponse(id, typeDefinitionResponse(params, workspace))
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
        sendResponse(id, hoverResponse(params, workspace, stdlib))
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
        sendResponse(id, completionResponse(params, workspace, stdlib))
    of "textDocument/inlayHint":
      if hasId:
        sendResponse(id, inlayHints(params, workspace))
    of "textDocument/documentSymbol":
      if hasId:
        sendResponse(id, documentSymbols(params, workspace))
    of "textDocument/documentLink":
      if hasId:
        sendResponse(id, documentLinks(params, workspace))
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
        sendResponse(id, signatureHelpResponse(params, workspace, stdlib))
    of "textDocument/semanticTokens/full":
      if hasId:
        sendResponse(id, semanticTokensResponse(params, workspace))
    of "workspace/symbol":
      if hasId:
        sendResponse(id, workspaceSymbols(params, workspace))
    of "$/cancelRequest":
      let requestId = params["id"]
      let cancellation =
        cancelPendingCodeAction(pendingCodeActions, queued, pending, requestId)
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
        discard cancelPendingWorkspaceRequest(pendingWorkspace, requestId)
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
          finishPendingCodeActionsForUri(pendingCodeActions, outcome.uri)
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
    stopBootstrapWorker()
    lspBootstrapBridge.joinThread()
    lspBootstrapBridgeStarted = false
  if lspInputReaderStarted:
    lspInputReader.joinThread()
    lspInputReaderStarted = false
  lspEvents.close()
  if exitRequested:
    quit(if shutdownRequested: 0 else: 1)
