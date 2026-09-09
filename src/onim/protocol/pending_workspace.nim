import std/json

import ../session/workspace
import ./call_hierarchy
import ./location_responses
import ./navigation
import ./rename
import ./transport

type
  PendingWorkspaceKind* = enum
    pendingDefinition
    pendingReferences
    pendingPrepareRename
    pendingRename
    pendingImplementation
    pendingPrepareCallHierarchy
    pendingIncomingCalls
    pendingOutgoingCalls

  PendingWorkspaceRequest* = object
    kind*: PendingWorkspaceKind
    id*: JsonNode
    params*: JsonNode

proc finishPendingWorkspace*(
    workspace: Workspace, pending: var seq[PendingWorkspaceRequest]
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
  pending.setLen(0)
