import std/json

import ./uris

proc valueOrEmpty*(node: JsonNode, key: string): JsonNode =
  if node != nil and node.kind == JObject and node.hasKey(key):
    node[key]
  else:
    newJObject()

type DocumentChange* = object
  valid*: bool
  uri*: string
  version*: int64
  changes*: JsonNode

proc validRequestId(node: JsonNode): bool {.inline.} =
  node != nil and node.kind in {JInt, JString}

proc validRequestEnvelope*(message: JsonNode): bool =
  if message == nil or message.kind != JObject or not message.hasKey("jsonrpc") or
      message["jsonrpc"].kind != JString or message["jsonrpc"].getStr != "2.0" or
      not message.hasKey("method") or message["method"].kind != JString:
    return false
  if message.hasKey("id") and not validRequestId(message["id"]):
    return false
  if message.hasKey("params") and (
    message["params"] == nil or message["params"].kind notin {JObject, JArray, JNull}
  ):
    return false
  true

proc validPositionValue(position: JsonNode): bool =
  if position == nil or position.kind != JObject or not position.hasKey("line") or
      not position.hasKey("character"):
    return false
  let line = position["line"]
  let character = position["character"]
  if line == nil or line.kind != JInt or character == nil or character.kind != JInt:
    return false
  line.getInt >= 0 and character.getInt >= 0 and line.getInt <= int64(high(int)) and
    character.getInt <= int64(high(int))

proc validRangeValue(value: JsonNode): bool =
  value != nil and value.kind == JObject and value.hasKey("start") and
    value.hasKey("end") and validPositionValue(value["start"]) and
    validPositionValue(value["end"])

proc validUriValue(node: JsonNode): bool =
  if node == nil or node.kind != JString or node.getStr.len == 0:
    return false
  try:
    uriToPath(node.getStr).len > 0
  except CatchableError:
    false

proc validTextDocumentParams*(params: JsonNode): bool =
  if params == nil or params.kind != JObject or not params.hasKey("textDocument"):
    return false
  let document = params["textDocument"]
  document != nil and document.kind == JObject and document.hasKey("uri") and
    validUriValue(document["uri"])

proc validPositionParams(params: JsonNode): bool =
  validTextDocumentParams(params) and params.hasKey("position") and
    validPositionValue(params["position"])

proc validSelectionRangeParams(params: JsonNode): bool =
  if not validTextDocumentParams(params) or not params.hasKey("positions") or
      params["positions"] == nil or params["positions"].kind != JArray:
    return false
  for position in params["positions"].items:
    if not validPositionValue(position):
      return false
  true

proc validInitializeParams(params: JsonNode): bool =
  if params == nil or params.kind != JObject:
    return false
  for key in ["rootUri", "rootPath"]:
    if params.hasKey(key) and params[key] != nil and
        params[key].kind notin {JString, JNull}:
      return false
  if not params.hasKey("workspaceFolders"):
    return true
  let folders = params["workspaceFolders"]
  if folders == nil or folders.kind == JNull:
    return true
  if folders.kind != JArray:
    return false
  for folder in folders.items:
    if folder == nil or folder.kind != JObject or not folder.hasKey("uri") or
        not validUriValue(folder["uri"]):
      return false
  true

proc validDidOpenParams(params: JsonNode): bool =
  if not validTextDocumentParams(params):
    return false
  let document = params["textDocument"]
  document.hasKey("version") and document["version"] != nil and
    document["version"].kind == JInt and document.hasKey("text") and
    document["text"] != nil and document["text"].kind == JString

proc validDidSaveParams(params: JsonNode): bool =
  validTextDocumentParams(params) and (
    not params.hasKey("text") or
    (params["text"] != nil and params["text"].kind == JString)
  )

proc validWatchedFileParams(params: JsonNode): bool =
  if params == nil or params.kind != JObject or not params.hasKey("changes") or
      params["changes"] == nil or params["changes"].kind != JArray:
    return false
  for change in params["changes"].items:
    if change == nil or change.kind != JObject or not change.hasKey("uri") or
        not validUriValue(change["uri"]) or not change.hasKey("type") or
        change["type"] == nil or change["type"].kind != JInt or change["type"].getInt < 1 or
        change["type"].getInt > 3:
      return false
  true

proc validReferencesParams(params: JsonNode): bool =
  if not validPositionParams(params) or not params.hasKey("context"):
    return false
  let context = params["context"]
  context != nil and context.kind == JObject and context.hasKey("includeDeclaration") and
    context["includeDeclaration"] != nil and context["includeDeclaration"].kind == JBool

proc validRenameParams(params: JsonNode): bool =
  validPositionParams(params) and params.hasKey("newName") and params["newName"] != nil and
    params["newName"].kind == JString

proc validCallHierarchyItemParams(params: JsonNode): bool =
  if params == nil or params.kind != JObject or not params.hasKey("item"):
    return false
  let item = params["item"]
  item != nil and item.kind == JObject and item.hasKey("uri") and
    validUriValue(item["uri"]) and item.hasKey("selectionRange") and
    validRangeValue(item["selectionRange"])

proc validCodeActionParams(params: JsonNode): bool =
  if not validTextDocumentParams(params) or not params.hasKey("context"):
    return false
  let context = params["context"]
  if context == nil or context.kind != JObject:
    return false
  if not context.hasKey("only"):
    return true
  let only = context["only"]
  if only == nil or only.kind != JArray:
    return false
  for item in only.items:
    if item == nil or item.kind != JString:
      return false
  true

proc validLifecycleParams(params: JsonNode): bool =
  params != nil and
    (params.kind == JNull or (params.kind == JObject and params.len == 0))

proc validCancelParams(params: JsonNode): bool =
  params != nil and params.kind == JObject and params.hasKey("id") and
    validRequestId(params["id"])

proc parseDocumentChange*(params: JsonNode): DocumentChange =
  if params == nil or params.kind != JObject or not params.hasKey("textDocument") or
      not params.hasKey("contentChanges"):
    return
  let document = params["textDocument"]
  let changes = params["contentChanges"]
  if document == nil or document.kind != JObject or not document.hasKey("uri") or
      document["uri"].kind != JString or document["uri"].getStr.len == 0 or
      not document.hasKey("version") or document["version"].kind != JInt or
      changes == nil or changes.kind != JArray or changes.len == 0:
    return

  var full = false
  var incremental = false
  for change in changes.items:
    if change == nil or change.kind != JObject or not change.hasKey("text") or
        change["text"].kind != JString:
      return
    if change.hasKey("range"):
      if not validRangeValue(change["range"]):
        return
      incremental = true
    else:
      full = true
    if full and incremental:
      return
  if full and changes.len != 1:
    return
  if not full and not incremental:
    return
  result.valid = true
  result.uri = document["uri"].getStr
  result.version = document["version"].getInt
  result.changes = changes

proc validMethodForm*(methodName: string, hasId: bool): bool =
  case methodName
  of "initialize", "shutdown", "textDocument/definition", "textDocument/typeDefinition",
      "textDocument/implementation", "textDocument/references", "textDocument/hover",
      "textDocument/prepareRename", "textDocument/rename", "textDocument/completion",
      "textDocument/documentSymbol", "textDocument/documentHighlight",
      "textDocument/foldingRange", "textDocument/selectionRange",
      "textDocument/signatureHelp", "textDocument/semanticTokens/full",
      "textDocument/semanticTokens/range", "textDocument/documentLink",
      "textDocument/inlayHint", "textDocument/codeAction", "workspace/symbol",
      "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls",
      "callHierarchy/outgoingCalls":
    hasId
  of "initialized", "textDocument/didOpen", "textDocument/didChange",
      "textDocument/didSave", "textDocument/didClose",
      "workspace/didChangeWatchedFiles", "$/cancelRequest", "exit":
    not hasId
  else:
    true

proc validMethodParams*(methodName: string, params: JsonNode): bool =
  case methodName
  of "initialize":
    validInitializeParams(params)
  of "initialized":
    params != nil and params.kind == JObject
  of "textDocument/didOpen":
    validDidOpenParams(params)
  of "textDocument/didChange":
    parseDocumentChange(params).valid
  of "textDocument/didSave":
    validDidSaveParams(params)
  of "textDocument/didClose":
    validTextDocumentParams(params)
  of "workspace/didChangeWatchedFiles":
    validWatchedFileParams(params)
  of "textDocument/definition", "textDocument/typeDefinition",
      "textDocument/implementation", "textDocument/hover", "textDocument/completion",
      "textDocument/documentHighlight", "textDocument/signatureHelp",
      "textDocument/prepareRename":
    validPositionParams(params)
  of "textDocument/prepareCallHierarchy":
    validPositionParams(params)
  of "callHierarchy/incomingCalls", "callHierarchy/outgoingCalls":
    validCallHierarchyItemParams(params)
  of "textDocument/inlayHint":
    validTextDocumentParams(params) and params.hasKey("range") and
      validRangeValue(params["range"])
  of "textDocument/references":
    validReferencesParams(params)
  of "textDocument/rename":
    validRenameParams(params)
  of "textDocument/documentSymbol":
    validTextDocumentParams(params)
  of "textDocument/documentLink":
    validTextDocumentParams(params)
  of "textDocument/foldingRange":
    validTextDocumentParams(params)
  of "textDocument/semanticTokens/full":
    validTextDocumentParams(params)
  of "textDocument/semanticTokens/range":
    validTextDocumentParams(params) and params.hasKey("range") and
      validRangeValue(params["range"])
  of "workspace/symbol":
    params != nil and params.kind == JObject and params.hasKey("query") and
      params["query"] != nil and params["query"].kind == JString
  of "textDocument/selectionRange":
    validSelectionRangeParams(params)
  of "textDocument/codeAction":
    validCodeActionParams(params)
  of "$/cancelRequest":
    validCancelParams(params)
  of "shutdown", "exit":
    validLifecycleParams(params)
  else:
    true
