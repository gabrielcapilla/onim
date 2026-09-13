import std/json

import ../session/workspace
import ../stdlib/map
import ./call_hierarchy
import ./completion_response
import ./location_responses
import ./navigation
import ./rename
import ./text_features
import ./transport

type
  PendingWorkspaceKind* = enum
    pendingDefinition
    pendingTypeDefinition
    pendingHover
    pendingCompletion
    pendingSignatureHelp
    pendingDocumentLink
    pendingReferences
    pendingPrepareRename
    pendingRename
    pendingImplementation
    pendingPrepareCallHierarchy
    pendingIncomingCalls
    pendingOutgoingCalls
    pendingWorkspaceSymbol

  PendingWorkspaceRequest* = object
    kind*: PendingWorkspaceKind
    id*: JsonNode
    params*: JsonNode

proc finishPendingWorkspace*(
    workspace: Workspace,
    stdlib: StdlibMap,
    pending: var seq[PendingWorkspaceRequest],
    useStdPrefix: bool,
    insertReplaceSupport: bool,
    snippetSupport: bool,
) =
  for item in pending:
    case item.kind
    of pendingDefinition:
      let response = definitionResponse(item.params, workspace)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingTypeDefinition:
      let response = typeDefinitionResponse(item.params, workspace)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingHover:
      let response = hoverResponse(item.params, workspace, stdlib)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingCompletion:
      let response = completionResponse(
        item.params, workspace, stdlib, useStdPrefix, insertReplaceSupport,
        snippetSupport,
      )
      if response.needsBootstrap:
        sendError(item.id, -32603, "Workspace completion data unavailable")
      else:
        sendResponse(item.id, response.value)
    of pendingSignatureHelp:
      let response = signatureHelpResponse(item.params, workspace, stdlib)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingDocumentLink:
      let response = documentLinks(item.params, workspace)
      sendResponse(item.id, response.value)
    of pendingReferences:
      let response = referencesResponse(item.params, workspace)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingPrepareRename:
      let response = prepareRenameResponse(item.params, workspace)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingRename:
      let response = renameResponse(item.params, workspace)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingImplementation:
      let response = implementationResponse(item.params, workspace)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingPrepareCallHierarchy, pendingIncomingCalls, pendingOutgoingCalls:
      let methodName =
        case item.kind
        of pendingPrepareCallHierarchy: "textDocument/prepareCallHierarchy"
        of pendingIncomingCalls: "callHierarchy/incomingCalls"
        of pendingOutgoingCalls: "callHierarchy/outgoingCalls"
        else: ""
      let response = callHierarchyResponse(methodName, item.params, workspace)
      sendResponse(
        item.id,
        if response.needsBootstrap:
          newJNull()
        else:
          response.value,
      )
    of pendingWorkspaceSymbol:
      sendResponse(item.id, workspaceSymbols(item.params, workspace))
  pending.setLen(0)

proc failPendingWorkspace*(
    pending: var seq[PendingWorkspaceRequest], code: int, message: string
) =
  for item in pending:
    sendError(item.id, code, message)
  pending.setLen(0)
