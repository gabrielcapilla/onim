import std/[json, streams, strutils, tables, uri]

import ./organize
import ./semantic_worker
import ./workspace
import ./workspace_ids

type
  CachedAction = object
    contentGeneration: ContentGeneration
    dependencyGeneration: DependencyGeneration
    configGeneration: ConfigGeneration
    useStdPrefix: bool
    edits: seq[ImportEdit]

  SemanticKey = object
    fileId: FileId
    contentGeneration: ContentGeneration
    dependencyGeneration: DependencyGeneration
    configGeneration: ConfigGeneration
    useStdPrefix: bool

proc sendMessage(message: JsonNode) =
  let body = $message
  stdout.write "Content-Length: " & $body.len & "\r\n\r\n"
  stdout.write body
  stdout.flushFile()

proc sendResponse(id, value: JsonNode) =
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["id"] = id
  message["result"] = value
  sendMessage(message)

proc sendError(id: JsonNode, code: int, messageText: string) =
  var error = newJObject()
  error["code"] = %code
  error["message"] = %messageText
  var response = newJObject()
  response["jsonrpc"] = %"2.0"
  response["id"] = id
  response["error"] = error
  sendMessage(response)

proc readMessage(): JsonNode =
  var contentLength = -1
  var line = ""
  while stdin.readLine(line):
    if line.len == 0:
      break
    let separator = line.find(':')
    if separator >= 0 and line[0 ..< separator].toLowerAscii == "content-length":
      try:
        contentLength = parseInt(line[separator + 1 .. ^1].strip)
      except ValueError:
        contentLength = -1
  if contentLength < 0:
    return nil
  try:
    let input = newFileStream(stdin)
    parseJson(input.readStr(contentLength))
  except CatchableError:
    nil

proc uriToPath(uriText: string): string =
  if uriText.startsWith("file://"):
    result = decodeUrl(uriText[7 .. ^1])
    when defined(windows):
      if result.len > 0 and result[0] == '/' and result.len > 2 and result[2] == ':':
        result = result[1 .. ^1]
      result = result.replace('/', '\\')
    else:
      if not result.startsWith("/"):
        result = "/" & result
  else:
    result = uriText

proc valueOrEmpty(node: JsonNode, key: string): JsonNode =
  if node != nil and node.kind == JObject and node.hasKey(key):
    node[key]
  else:
    newJObject()

proc boolOption(params: JsonNode, key: string, fallback: bool): bool =
  let options = valueOrEmpty(params, "initializationOptions")
  if options.kind == JObject and options.hasKey(key) and options[key].kind == JBool:
    options[key].getBool
  else:
    fallback

proc utf16Width(source: string, index, limit: int): tuple[nextIndex, units: int] =
  let first = ord(source[index])
  var codepoint = first
  var width = 1
  if (first and 0xE0) == 0xC0 and index + 1 < limit and
      (ord(source[index + 1]) and 0xC0) == 0x80:
    codepoint = ((first and 0x1F) shl 6) or (ord(source[index + 1]) and 0x3F)
    width = 2
  elif (first and 0xF0) == 0xE0 and index + 2 < limit and
      (ord(source[index + 1]) and 0xC0) == 0x80 and
      (ord(source[index + 2]) and 0xC0) == 0x80:
    codepoint =
      ((first and 0x0F) shl 12) or ((ord(source[index + 1]) and 0x3F) shl 6) or
      (ord(source[index + 2]) and 0x3F)
    width = 3
  elif (first and 0xF8) == 0xF0 and index + 3 < limit and
      (ord(source[index + 1]) and 0xC0) == 0x80 and
      (ord(source[index + 2]) and 0xC0) == 0x80 and
      (ord(source[index + 3]) and 0xC0) == 0x80:
    codepoint =
      ((first and 0x07) shl 18) or ((ord(source[index + 1]) and 0x3F) shl 12) or
      ((ord(source[index + 2]) and 0x3F) shl 6) or (ord(source[index + 3]) and 0x3F)
    width = 4
  (min(limit, index + width), if codepoint > 0xFFFF: 2 else: 1)

proc positionAt(source: string, offset: int): JsonNode =
  var line = 0
  var column = 0
  let limit = max(0, min(offset, source.len))
  var index = 0
  while index < limit:
    if source[index] == '\n':
      inc line
      column = 0
      inc index
    else:
      let advance = utf16Width(source, index, limit)
      index = advance.nextIndex
      column += advance.units
  %*{"line": line, "character": column}

proc editJson(source: string, edit: ImportEdit): JsonNode =
  %*{
    "range": {
      "start": positionAt(source, edit.startOffset),
      "end": positionAt(source, edit.endOffset),
    },
    "newText": edit.newText,
  }

proc intOption(node: JsonNode, key: string, fallback: int64): int64 =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    int64(node[key].getInt)
  else:
    fallback

proc initializeRoot(params: JsonNode): string =
  if params != nil and params.kind == JObject:
    if params.hasKey("rootUri") and params["rootUri"].kind == JString:
      let uriText = params["rootUri"].getStr
      if uriText.len > 0:
        return uriToPath(uriText)
    if params.hasKey("rootPath") and params["rootPath"].kind == JString:
      let rootPath = params["rootPath"].getStr
      if rootPath.len > 0:
        return rootPath
    if params.hasKey("workspaceFolders") and params["workspaceFolders"].kind == JArray:
      for folder in params["workspaceFolders"].items:
        if folder.kind == JObject and folder.hasKey("uri") and
            folder["uri"].kind == JString:
          return uriToPath(folder["uri"].getStr)
  ""

proc supportsOrganize(params: JsonNode): bool =
  if params == nil or not params.hasKey("context"):
    return true
  let context = params["context"]
  if context.kind != JObject or not context.hasKey("only"):
    return true
  let only = context["only"]
  if only.kind != JArray:
    return true
  for item in only.items:
    if item.kind == JString and
        (item.getStr == "source" or item.getStr == "source.organizeImports"):
      return true
  false

proc semanticKey(snapshot: WorkspaceSnapshot, options: OrganizeOptions): SemanticKey =
  SemanticKey(
    fileId: snapshot.fileId,
    contentGeneration: snapshot.contentGeneration,
    dependencyGeneration: snapshot.dependencyGeneration,
    configGeneration: snapshot.configGeneration,
    useStdPrefix: options.useStdPrefix,
  )

proc semanticKey(value: SemanticResult): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc semanticKey(value: SemanticRequest): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc sameSemanticKey(left, right: SemanticKey): bool =
  left.fileId.value == right.fileId.value and
    left.contentGeneration.value == right.contentGeneration.value and
    left.dependencyGeneration.value == right.dependencyGeneration.value and
    left.configGeneration.value == right.configGeneration.value and
    left.useStdPrefix == right.useStdPrefix

proc removePending(pending: var seq[SemanticKey], key: SemanticKey) =
  for index, existing in pending:
    if sameSemanticKey(existing, key):
      pending.delete(index)
      return

proc removeQueued(queued: var seq[SemanticRequest], fileId: FileId) =
  var writeIndex = 0
  for request in queued:
    if request.fileId.value != fileId.value:
      queued[writeIndex] = request
      inc writeIndex
  queued.setLen(writeIndex)

proc queueSemantic(queued: var seq[SemanticRequest], request: SemanticRequest) =
  removeQueued(queued, request.fileId)
  queued.add request

proc dispatchSemantic(
    queued: var seq[SemanticRequest], pending: var seq[SemanticKey]
): bool =
  if pending.len > 0 or queued.len == 0:
    return false
  let request = queued[0]
  queued.delete(0)
  if not submitSemantic(request):
    return false
  pending.add semanticKey(request)
  true

proc actionIsCurrent(
    action: CachedAction, snapshot: WorkspaceSnapshot, options: OrganizeOptions
): bool =
  action.contentGeneration.value == snapshot.contentGeneration.value and
    action.dependencyGeneration.value == snapshot.dependencyGeneration.value and
    action.configGeneration.value == snapshot.configGeneration.value and
    action.useStdPrefix == options.useStdPrefix

proc enqueueSemantic(
    snapshot: WorkspaceSnapshot,
    options: OrganizeOptions,
    pending: var seq[SemanticKey],
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
    useStdPrefix: options.useStdPrefix,
  )
  let key = semanticKey(request)
  for existing in pending:
    if sameSemanticKey(existing, key):
      return true
  queueSemantic(queued, request)
  if pending.len == 0 and not dispatchSemantic(queued, pending):
    removeQueued(queued, request.fileId)
    return false
  true

proc acceptSemantic(
    value: SemanticResult,
    workspace: Workspace,
    actionCache: var Table[uint32, CachedAction],
    pending: var seq[SemanticKey],
    queued: var seq[SemanticRequest],
) =
  if value.failed or not value.fileId.valid:
    pending.setLen(0)
    queued.setLen(0)
    return
  let key = semanticKey(value)
  removePending(pending, key)
  let snapshot = workspace.snapshotForFile(value.fileId)
  if snapshot.valid and
      sameSemanticKey(
        semanticKey(snapshot, OrganizeOptions(useStdPrefix: value.useStdPrefix)), key
      ):
    actionCache[uint32(value.fileId)] = CachedAction(
      contentGeneration: value.contentGeneration,
      dependencyGeneration: value.dependencyGeneration,
      configGeneration: value.configGeneration,
      useStdPrefix: value.useStdPrefix,
      edits: value.edits,
    )
  discard dispatchSemantic(queued, pending)

proc drainSemantic(
    workspace: Workspace,
    actionCache: var Table[uint32, CachedAction],
    pending: var seq[SemanticKey],
    queued: var seq[SemanticRequest],
) =
  var result: SemanticResult
  while tryReceiveSemantic(result):
    acceptSemantic(result, workspace, actionCache, pending, queued)

proc waitForSemantic(
    key: SemanticKey,
    workspace: Workspace,
    actionCache: var Table[uint32, CachedAction],
    pending: var seq[SemanticKey],
    queued: var seq[SemanticRequest],
): bool =
  while true:
    let snapshot = workspace.snapshotForFile(key.fileId)
    if snapshot.valid and actionCache.hasKey(uint32(key.fileId)) and
        actionIsCurrent(
          actionCache[uint32(key.fileId)],
          snapshot,
          OrganizeOptions(useStdPrefix: key.useStdPrefix),
        ):
      return true
    let result = receiveSemantic()
    if result.failed:
      pending.setLen(0)
      queued.setLen(0)
      return false
    acceptSemantic(result, workspace, actionCache, pending, queued)

proc codeActions(
    params: JsonNode,
    workspace: Workspace,
    actionCache: var Table[uint32, CachedAction],
    pending: var seq[SemanticKey],
    queued: var seq[SemanticRequest],
    options: OrganizeOptions,
): JsonNode =
  drainSemantic(workspace, actionCache, pending, queued)
  if not supportsOrganize(params):
    return newJArray()
  let textDocument = valueOrEmpty(params, "textDocument")
  let uriText =
    if textDocument.hasKey("uri"):
      textDocument["uri"].getStr
    else:
      ""
  let path = uriToPath(uriText)
  if path.toLowerAscii.endsWith(".nimble") or path.toLowerAscii.endsWith(".cfg"):
    return newJArray()
  let snapshot = workspace.snapshotForDocument(uriText, path)
  if not snapshot.valid:
    return newJArray()
  let cacheKey = uint32(snapshot.fileId)
  var edits: seq[ImportEdit] = @[]
  var cacheHit = false
  if actionCache.hasKey(cacheKey):
    let cached = actionCache[cacheKey]
    if actionIsCurrent(cached, snapshot, options):
      edits = cached.edits
      cacheHit = true
  if not cacheHit:
    let key = semanticKey(snapshot, options)
    if enqueueSemantic(snapshot, options, pending, queued):
      discard waitForSemantic(key, workspace, actionCache, pending, queued)
      drainSemantic(workspace, actionCache, pending, queued)
      if actionCache.hasKey(cacheKey) and
          actionIsCurrent(actionCache[cacheKey], snapshot, options):
        edits = actionCache[cacheKey].edits
    else:
      if snapshot.index != nil:
        edits = organizeSourceWithImports(
          snapshot.path, snapshot.text, snapshot.index.parsed, options
        )
      else:
        edits = organizeSource(snapshot.path, snapshot.text, options)
      actionCache[cacheKey] = CachedAction(
        contentGeneration: snapshot.contentGeneration,
        dependencyGeneration: snapshot.dependencyGeneration,
        configGeneration: snapshot.configGeneration,
        useStdPrefix: options.useStdPrefix,
        edits: edits,
      )
  if edits.len == 0:
    return newJArray()
  var workspaceEdit = newJObject()
  var uriEdits = newJArray()
  for edit in edits:
    uriEdits.add editJson(snapshot.text, edit)
  workspaceEdit["changes"] = newJObject()
  workspaceEdit["changes"][uriText] = uriEdits
  var action = newJObject()
  action["title"] = %"Organize Nim imports"
  action["kind"] = %"source.organizeImports"
  action["edit"] = workspaceEdit
  result = newJArray()
  result.add action

proc runLsp*() =
  let workspace = initWorkspace()
  var actionCache = initTable[uint32, CachedAction]()
  var pending: seq[SemanticKey] = @[]
  var queued: seq[SemanticRequest] = @[]
  var options = defaultOrganizeOptions()
  var shutdownRequested = false
  discard startSemanticWorker()
  while not endOfFile(stdin):
    let message = readMessage()
    if message == nil:
      break
    let methodName =
      if message.hasKey("method"):
        message["method"].getStr
      else:
        ""
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
    case methodName
    of "initialize":
      let root = initializeRoot(params)
      if root.len > 0:
        workspace.indexWorkspace(root)
      options.useStdPrefix = boolOption(params, "useStdPrefix", true)
      var provider = newJObject()
      provider["codeActionKinds"] = %*["source.organizeImports"]
      provider["resolveProvider"] = %false
      var sync = newJObject()
      sync["openClose"] = %true
      sync["change"] = %1
      sync["save"] = %*{"includeText": true}
      var capabilities = newJObject()
      capabilities["textDocumentSync"] = sync
      capabilities["codeActionProvider"] = provider
      capabilities["positionEncoding"] = %"utf-16"
      var result = newJObject()
      result["capabilities"] = capabilities
      result["serverInfo"] = %*{"name": "onim", "version": "0.1.0"}
      if hasId:
        sendResponse(id, result)
    of "initialized":
      discard
    of "shutdown":
      shutdownRequested = true
      if hasId:
        sendResponse(id, newJNull())
    of "exit":
      stopSemanticWorker()
      quit(if shutdownRequested: 0 else: 1)
    of "textDocument/didOpen":
      let textDocument = valueOrEmpty(params, "textDocument")
      if textDocument.hasKey("uri") and textDocument.hasKey("text"):
        let uriText = textDocument["uri"].getStr
        let path = uriToPath(uriText)
        discard workspace.openDocument(
          uriText,
          path,
          textDocument["text"].getStr,
          intOption(textDocument, "version", -1),
        )
        discard enqueueSemantic(
          workspace.snapshotForDocument(uriText, path), options, pending, queued
        )
    of "textDocument/didChange":
      let textDocument = valueOrEmpty(params, "textDocument")
      let uriText =
        if textDocument.hasKey("uri"):
          textDocument["uri"].getStr
        else:
          ""
      var changedText = ""
      var hasChangedText = false
      if uriText.len > 0 and params.hasKey("contentChanges") and
          params["contentChanges"].kind == JArray:
        for change in params["contentChanges"].items:
          if change.kind == JObject and change.hasKey("text"):
            changedText = change["text"].getStr
            hasChangedText = true
      if uriText.len > 0 and hasChangedText:
        let path = uriToPath(uriText)
        discard workspace.changeDocument(
          uriText, path, changedText, intOption(textDocument, "version", -1)
        )
        discard enqueueSemantic(
          workspace.snapshotForDocument(uriText, path), options, pending, queued
        )
    of "textDocument/didClose":
      let textDocument = valueOrEmpty(params, "textDocument")
      if textDocument.hasKey("uri"):
        let uriText = textDocument["uri"].getStr
        workspace.closeDocument(uriText, uriToPath(uriText))
    of "textDocument/didSave":
      let textDocument = valueOrEmpty(params, "textDocument")
      if textDocument.hasKey("uri"):
        let uriText = textDocument["uri"].getStr
        let path = uriToPath(uriText)
        if params.hasKey("text") and params["text"].kind == JString:
          discard workspace.changeDocument(uriText, path, params["text"].getStr, -1)
        discard enqueueSemantic(
          workspace.snapshotForDocument(uriText, path), options, pending, queued
        )
    of "workspace/didChangeWatchedFiles":
      let changes = valueOrEmpty(params, "changes")
      if changes.kind == JArray:
        for change in changes.items:
          if change.kind != JObject or not change.hasKey("uri"):
            continue
          let path = uriToPath(change["uri"].getStr)
          let changeType = intOption(change, "type", 2)
          workspace.fileChanged(path, changeType == 3)
    of "$/cancelRequest":
      discard
    of "textDocument/codeAction":
      if hasId:
        sendResponse(
          id, codeActions(params, workspace, actionCache, pending, queued, options)
        )
    else:
      if hasId:
        sendError(id, -32601, "method not supported: " & methodName)
  stopSemanticWorker()
