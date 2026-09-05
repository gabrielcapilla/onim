import std/[json, streams, strutils, tables, uri]

import ../features/definition
import ../features/organize
import ../semantic/native_diagnostics
import ../semantic/worker
import ../session/bootstrap_worker
import ../session/ids
import ../session/workspace
import ../index/symbols
import ../stdlib/map
import ../syntax/lexer

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

  LspEventKind = enum
    lspMessageEvent
    lspBootstrapEvent
    lspEndEvent

  LspEvent = object
    kind: LspEventKind
    payload: string

  BootstrapRuntime = object
    active: bool
    hasPending: bool
    nextJobGeneration: uint64
    pending: BootstrapRequest

  PendingDefinition = object
    id: JsonNode
    params: JsonNode

  PositionIndex = object
    lineStarts: seq[int]

proc hasCachedAction(cache: seq[CachedAction], id: FileId): bool {.inline.} =
  let slot = id.slot
  slot >= 0 and slot < cache.len and
    cache[slot].contentGeneration.value != InvalidContentGeneration.value

proc cachedActionFor(cache: seq[CachedAction], id: FileId): CachedAction {.inline.} =
  let slot = id.slot
  if slot >= 0 and slot < cache.len:
    result = cache[slot]

proc storeCachedAction(
    cache: var seq[CachedAction], id: FileId, action: CachedAction
) {.inline.} =
  let slot = id.slot
  if slot < 0:
    return
  if slot >= cache.len:
    cache.setLen(slot + 1)
  cache[slot] = action

var lspEvents: Channel[LspEvent]
var lspInputReader: Thread[void]
var lspBootstrapBridge: Thread[void]
var lspInputReaderStarted = false
var lspBootstrapBridgeStarted = false

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

proc readMessageText(): string {.gcsafe.} =
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
    return
  try:
    let input = newFileStream(stdin)
    result = input.readStr(contentLength)
  except CatchableError:
    result = ""

proc readInputEvents() {.thread, gcsafe.} =
  while true:
    let payload = readMessageText()
    if payload.len == 0:
      lspEvents.send(LspEvent(kind: lspEndEvent))
      break
    lspEvents.send(LspEvent(kind: lspMessageEvent, payload: payload))

proc bootstrapEventBridge() {.thread, gcsafe.} =
  while true:
    let value = receiveBootstrap()
    lspEvents.send(
      LspEvent(kind: lspBootstrapEvent, payload: encodeBootstrapResult(value))
    )
    if value.kind == bootstrapStopped:
      break

proc parseMessage(payload: string): JsonNode =
  try:
    parseJson(payload)
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

proc intOption(node: JsonNode, key: string, fallback: int64): int64 =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    int64(node[key].getInt)
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

proc initPositionIndex(source: string): PositionIndex =
  result.lineStarts = @[0]
  for offset, character in source:
    if character == '\n':
      result.lineStarts.add offset + 1

proc lineAt(index: PositionIndex, offset: int): int {.inline.} =
  var low = 0
  var high = index.lineStarts.high
  while low <= high:
    let middle = (low + high) shr 1
    if index.lineStarts[middle] <= offset:
      low = middle + 1
    else:
      high = middle - 1
  max(0, low - 1)

proc positionAt(index: PositionIndex, source: string, offset: int): JsonNode =
  var column = 0
  let limit = max(0, min(offset, source.len))
  let line = index.lineAt(limit)
  var cursor = index.lineStarts[line]
  while cursor < limit:
    let advance = utf16Width(source, cursor, limit)
    cursor = advance.nextIndex
    column += advance.units
  %*{"line": line, "character": column}

proc positionAt(source: string, offset: int): JsonNode =
  positionAt(initPositionIndex(source), source, offset)

proc offsetAt(index: PositionIndex, source: string, position: JsonNode): int =
  if position == nil or position.kind != JObject:
    return -1
  let lineValue = intOption(position, "line", -1)
  let characterValue = intOption(position, "character", -1)
  if lineValue < 0 or characterValue < 0 or lineValue > int64(high(int)) or
      characterValue > int64(high(int)):
    return -1
  let wantedLine = int(lineValue)
  let wantedCharacter = int(characterValue)
  if wantedLine >= index.lineStarts.len:
    return -1

  let lineStart = index.lineStarts[wantedLine]
  var lineEnd = lineStart
  while lineEnd < source.len and source[lineEnd] != '\n':
    inc lineEnd
  var character = 0
  var cursor = lineStart
  while cursor < lineEnd:
    if character == wantedCharacter:
      return cursor
    let advance = utf16Width(source, cursor, lineEnd)
    if character + advance.units > wantedCharacter:
      return -1
    character += advance.units
    cursor = advance.nextIndex
  if character == wantedCharacter: cursor else: -1

proc offsetAt(source: string, position: JsonNode): int =
  offsetAt(initPositionIndex(source), source, position)

proc utf16Length(value: string): int =
  var index = 0
  while index < value.len:
    let advance = utf16Width(value, index, value.len)
    result += advance.units
    index = advance.nextIndex

proc uriPathByte(character: char): bool =
  (character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z') or
    (character >= '0' and character <= '9') or
    character in {'-', '.', '_', '~', '/', ':'}

proc hexDigit(value: int): char =
  if value < 10:
    char(ord('0') + value)
  else:
    char(ord('A') + value - 10)

proc fileUri(path: string): string =
  result = "file://"
  for character in path:
    let normalized =
      when defined(windows):
        if character == '\\': '/' else: character
      else:
        character
    if normalized.uriPathByte:
      result.add normalized
    else:
      let value = ord(normalized)
      result.add '%'
      result.add hexDigit((value shr 4) and 0x0F)
      result.add hexDigit(value and 0x0F)

proc nativeDiagnosticMessage(diagnostic: NativeDiagnostic): string =
  case diagnostic.kind
  of nativeMalformedIdentifier:
    "malformed identifier"
  of nativeUnclosedString:
    "unterminated string literal"
  of nativeUnexpectedDelimiter:
    "unexpected closing delimiter"
  of nativeUnclosedDelimiter:
    "unclosed delimiter"
  of nativeMissingStdlibImport:
    "missing import: " & diagnostic.module
  of nativeMissingProjectImport:
    "missing project import: " & diagnostic.module

proc sendNativeDiagnostics(uri, source: string, diagnostics: seq[NativeDiagnostic]) =
  let positions = initPositionIndex(source)
  var values = newJArray()
  for diagnostic in diagnostics:
    var range = newJObject()
    range["start"] = positionAt(positions, source, diagnostic.startOffset)
    range["end"] = positionAt(positions, source, diagnostic.endOffset)
    var value = newJObject()
    value["range"] = range
    value["severity"] = %1
    value["source"] = %"onim"
    value["message"] = %nativeDiagnosticMessage(diagnostic)
    values.add value

  var params = newJObject()
  params["uri"] = %uri
  params["diagnostics"] = values
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["method"] = %"textDocument/publishDiagnostics"
  message["params"] = params
  sendMessage(message)

proc publishNativeDiagnostics(
    workspace: Workspace, snapshot: WorkspaceSnapshot, stdlib: StdlibMap
) =
  let uri =
    if snapshot.uri.len > 0:
      snapshot.uri
    else:
      fileUri(snapshot.path)
  if uri.len == 0:
    return
  let diagnostics =
    if snapshot.valid and snapshot.index != nil:
      nativeDiagnostics(
        snapshot.index,
        stdlib,
        if workspace.graphComplete:
          workspace.projectSurface()
        else:
          nil,
        workspace.moduleForPath(snapshot.path),
        workspace.moduleCatalog(),
      )
    else:
      @[]
  if diagnostics.len == 0 and workspace.bootstrapState != workspaceBootstrapComplete:
    return
  sendNativeDiagnostics(uri, snapshot.text, diagnostics)

proc clearNativeDiagnostics(uri: string) =
  if uri.len > 0:
    sendNativeDiagnostics(uri, "", @[])

proc targetTokenLength(token: Token): int =
  let byteLength = token.endOffset - token.startOffset
  if byteLength == token.text.len:
    return utf16Length(token.text)
  if byteLength == token.text.len + 2:
    return utf16Length(token.text) + 2
  -1

proc definitionLocation(
    source: WorkspaceSnapshot,
    sourceUri: string,
    view: WorkspaceIndexView,
    target: DefinitionTarget,
    positions: PositionIndex,
): JsonNode =
  if not view.valid or view.index == nil or view.id.value != target.snapshotId.value or
      view.contentGeneration.value != target.contentGeneration.value or
      int(target.nameToken) >= view.index.parsed.tokens.len:
    return
  let token = view.index.parsed.tokens[int(target.nameToken)]
  let uri =
    if view.uri.len > 0:
      view.uri
    else:
      fileUri(view.path)
  var start: JsonNode
  var finish: JsonNode
  if view.fileId.value == source.fileId.value:
    start = positionAt(positions, source.text, token.startOffset)
    finish = positionAt(positions, source.text, token.endOffset)
  else:
    let length = targetTokenLength(token)
    if token.line < 0 or token.column < 0 or length < 0:
      return
    start = %*{"line": token.line, "character": token.column}
    finish = %*{"line": token.line, "character": token.column + length}
  %*{
    "uri": if view.fileId.value == source.fileId.value: sourceUri else: uri,
    "range": {"start": start, "end": finish},
  }

proc definitionResponse(
    params: JsonNode, workspace: Workspace
): tuple[value: JsonNode, needsBootstrap: bool] =
  result.value = newJNull()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString:
    return
  let uriText = textDocument["uri"].getStr
  let path = uriToPath(uriText)
  if path.len == 0 or path.toLowerAscii.endsWith(".nimble") or
      path.toLowerAscii.endsWith(".cfg"):
    return
  let snapshot = workspace.snapshotForDocument(uriText, path)
  if not snapshot.valid:
    return
  let positions = initPositionIndex(snapshot.text)
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let resolution = resolveDefinition(workspace, snapshot, offset)
  result.needsBootstrap = resolution.kind == definitionUnresolved
  if resolution.kind != definitionResolved:
    return
  let view = workspace.indexViewForFile(resolution.target.fileId)
  result.value =
    definitionLocation(snapshot, uriText, view, resolution.target, positions)
  if result.value == nil:
    result.value = newJNull()

proc documentSymbolKind(kind: SourceSymbolKind): int =
  case kind
  of symbolMethod:
    6
  of symbolType:
    23
  of symbolVar, symbolLet:
    13
  of symbolConst:
    14
  of symbolProc, symbolFunc, symbolIterator, symbolMacro, symbolTemplate,
      symbolConverter:
    12

proc documentSymbols(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString:
    return
  let uriText = textDocument["uri"].getStr
  let path = uriToPath(uriText)
  if path.len == 0 or path.toLowerAscii.endsWith(".nimble") or
      path.toLowerAscii.endsWith(".cfg"):
    return
  let snapshot = workspace.snapshotForDocument(uriText, path)
  if not snapshot.valid or snapshot.index == nil:
    return
  let positions = initPositionIndex(snapshot.text)
  for symbol in snapshot.index.symbols:
    let tokenIndex = int(symbol.nameToken)
    if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
      continue
    let token = snapshot.index.parsed.tokens[tokenIndex]
    if token.kind != tkIdentifier or token.startOffset < 0 or
        token.endOffset > snapshot.text.len or token.endOffset <= token.startOffset:
      continue
    let start = positionAt(positions, snapshot.text, token.startOffset)
    let finish = positionAt(positions, snapshot.text, token.endOffset)
    result.add %*{
      "name": token.text,
      "kind": documentSymbolKind(symbol.kind),
      "range": {"start": start, "end": finish},
      "selectionRange": {"start": start, "end": finish},
    }

proc editJson(source: string, positions: PositionIndex, edit: ImportEdit): JsonNode =
  %*{
    "range": {
      "start": positionAt(positions, source, edit.startOffset),
      "end": positionAt(positions, source, edit.endOffset),
    },
    "newText": edit.newText,
  }

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

proc cacheIndexedAction(
    snapshot: WorkspaceSnapshot,
    options: OrganizeOptions,
    stdlib: var StdlibMap,
    actionCache: var seq[CachedAction],
): tuple[handled: bool, edits: seq[ImportEdit]] =
  if not snapshot.valid:
    return
  if stdlib == nil:
    stdlib = stdlibMap()
  let attempt = tryOrganizeSourceWithIndex(
    snapshot.path, snapshot.text, snapshot.index, stdlib, options
  )
  if not attempt.handled:
    return
  result.handled = true
  result.edits = attempt.edits
  storeCachedAction(
    actionCache,
    snapshot.fileId,
    CachedAction(
      contentGeneration: snapshot.contentGeneration,
      dependencyGeneration: snapshot.dependencyGeneration,
      configGeneration: snapshot.configGeneration,
      useStdPrefix: options.useStdPrefix,
      edits: result.edits,
    ),
  )

proc acceptSemantic(
    value: SemanticResult,
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var seq[SemanticKey],
    queued: var seq[SemanticRequest],
) =
  if value.failed:
    if value.fileId.valid:
      removePending(pending, semanticKey(value))
      discard dispatchSemantic(queued, pending)
    else:
      pending.setLen(0)
      queued.setLen(0)
    return
  if not value.fileId.valid:
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
    storeCachedAction(
      actionCache,
      value.fileId,
      CachedAction(
        contentGeneration: value.contentGeneration,
        dependencyGeneration: value.dependencyGeneration,
        configGeneration: value.configGeneration,
        useStdPrefix: value.useStdPrefix,
        edits: value.edits,
      ),
    )
  discard dispatchSemantic(queued, pending)

proc drainSemantic(
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var seq[SemanticKey],
    queued: var seq[SemanticRequest],
) =
  var result: SemanticResult
  while tryReceiveSemantic(result):
    acceptSemantic(result, workspace, actionCache, pending, queued)

proc waitForSemantic(
    key: SemanticKey,
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var seq[SemanticKey],
    queued: var seq[SemanticRequest],
): bool =
  while true:
    let snapshot = workspace.snapshotForFile(key.fileId)
    if snapshot.valid and hasCachedAction(actionCache, key.fileId) and
        actionIsCurrent(
          cachedActionFor(actionCache, key.fileId),
          snapshot,
          OrganizeOptions(useStdPrefix: key.useStdPrefix),
        ):
      return true
    let semanticResult = receiveSemantic()
    if semanticResult.failed:
      if not semanticResult.fileId.valid:
        pending.setLen(0)
        queued.setLen(0)
      else:
        acceptSemantic(semanticResult, workspace, actionCache, pending, queued)
      return false
    acceptSemantic(semanticResult, workspace, actionCache, pending, queued)

proc codeActions(
    params: JsonNode,
    workspace: Workspace,
    stdlib: var StdlibMap,
    actionCache: var seq[CachedAction],
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
  let cacheKey = snapshot.fileId
  var edits: seq[ImportEdit] = @[]
  var cacheHit = false
  if hasCachedAction(actionCache, cacheKey):
    let cached = cachedActionFor(actionCache, cacheKey)
    if actionIsCurrent(cached, snapshot, options):
      edits = cached.edits
      cacheHit = true
  if not cacheHit:
    let indexed = cacheIndexedAction(snapshot, options, stdlib, actionCache)
    if indexed.handled:
      edits = indexed.edits
    else:
      let key = semanticKey(snapshot, options)
      if enqueueSemantic(snapshot, options, pending, queued):
        discard waitForSemantic(key, workspace, actionCache, pending, queued)
        drainSemantic(workspace, actionCache, pending, queued)
        if hasCachedAction(actionCache, cacheKey) and
            actionIsCurrent(cachedActionFor(actionCache, cacheKey), snapshot, options):
          edits = cachedActionFor(actionCache, cacheKey).edits
      else:
        if snapshot.index != nil:
          edits = organizeSourceWithIndex(
            snapshot.path, snapshot.text, snapshot.index, options
          )
        else:
          edits = organizeSource(snapshot.path, snapshot.text, options)
        storeCachedAction(
          actionCache,
          snapshot.fileId,
          CachedAction(
            contentGeneration: snapshot.contentGeneration,
            dependencyGeneration: snapshot.dependencyGeneration,
            configGeneration: snapshot.configGeneration,
            useStdPrefix: options.useStdPrefix,
            edits: edits,
          ),
        )
  if edits.len == 0:
    return newJArray()
  let positions = initPositionIndex(snapshot.text)
  var workspaceEdit = newJObject()
  var uriEdits = newJArray()
  for edit in edits:
    uriEdits.add editJson(snapshot.text, positions, edit)
  workspaceEdit["changes"] = newJObject()
  workspaceEdit["changes"][uriText] = uriEdits
  var action = newJObject()
  action["title"] = %"Organize Nim imports"
  action["kind"] = %"source.organizeImports"
  action["edit"] = workspaceEdit
  result = newJArray()
  result.add action

proc scheduleBootstrap(runtime: var BootstrapRuntime, workspace: Workspace) =
  if workspace == nil or workspace.root.len == 0:
    return
  inc runtime.nextJobGeneration
  let request = BootstrapRequest(
    jobGeneration: runtime.nextJobGeneration,
    workspaceGeneration: workspace.workspaceGeneration(),
    configGeneration: workspace.configurationGeneration,
    root: workspace.root,
  )
  if runtime.active:
    runtime.pending = request
    runtime.hasPending = true
    cancelBootstrap(request.jobGeneration)
  elif submitBootstrap(request):
    runtime.active = true

proc publishOpenNativeDiagnostics(workspace: Workspace, stdlib: StdlibMap) =
  for id in workspace.openDocumentIds:
    let snapshot = workspace.snapshotForFile(id)
    publishNativeDiagnostics(workspace, snapshot, stdlib)

proc finishPendingDefinitions(
    workspace: Workspace, pending: var seq[PendingDefinition]
) =
  for item in pending:
    let response = definitionResponse(item.params, workspace)
    if response.needsBootstrap:
      sendResponse(item.id, newJNull())
    else:
      sendResponse(item.id, response.value)
  pending.setLen(0)

proc handleBootstrapEvent(
    runtime: var BootstrapRuntime,
    workspace: Workspace,
    pendingDefinitions: var seq[PendingDefinition],
    stdlib: StdlibMap,
    payload: string,
): bool =
  let value = decodeBootstrapResult(payload)
  if value.kind == bootstrapStopped:
    return false
  runtime.active = false
  let accepted = workspace.applyBootstrap(value)
  if accepted:
    publishOpenNativeDiagnostics(workspace, stdlib)
    finishPendingDefinitions(workspace, pendingDefinitions)
  elif value.kind == bootstrapFailed:
    finishPendingDefinitions(workspace, pendingDefinitions)
  if runtime.hasPending:
    let request = runtime.pending
    runtime.hasPending = false
    if submitBootstrap(request):
      runtime.active = true
  accepted

proc runLsp*() =
  let workspace = initWorkspace()
  var stdlib = stdlibMap()
  var actionCache: seq[CachedAction] = @[]
  var pending: seq[SemanticKey] = @[]
  var queued: seq[SemanticRequest] = @[]
  var pendingDefinitions: seq[PendingDefinition] = @[]
  var bootstrap: BootstrapRuntime
  var options = defaultOrganizeOptions()
  var shutdownRequested = false
  var exitRequested = false

  lspEvents.open()
  lspInputReaderStarted = false
  lspBootstrapBridgeStarted = false
  discard startSemanticWorker()
  if startBootstrapWorker():
    createThread(lspBootstrapBridge, bootstrapEventBridge)
    lspBootstrapBridgeStarted = true
  createThread(lspInputReader, readInputEvents)
  lspInputReaderStarted = true

  while true:
    let event = lspEvents.recv()
    if event.kind == lspEndEvent:
      break
    if event.kind == lspBootstrapEvent:
      if decodeBootstrapResult(event.payload).kind != bootstrapStopped:
        discard handleBootstrapEvent(
          bootstrap, workspace, pendingDefinitions, stdlib, event.payload
        )
      continue

    let message = parseMessage(event.payload)
    if message == nil or message.kind != JObject:
      continue
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
        discard workspace.prepareWorkspace(root)
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
      capabilities["definitionProvider"] = %true
      capabilities["documentSymbolProvider"] = %true
      capabilities["positionEncoding"] = %"utf-16"
      var result = newJObject()
      result["capabilities"] = capabilities
      result["serverInfo"] = %*{"name": "onim", "version": "0.1.0"}
      if hasId:
        sendResponse(id, result)
      scheduleBootstrap(bootstrap, workspace)
    of "initialized":
      discard
    of "shutdown":
      shutdownRequested = true
      if hasId:
        sendResponse(id, newJNull())
    of "exit":
      exitRequested = true
      break
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
        let snapshot = workspace.snapshotForDocument(uriText, path)
        publishNativeDiagnostics(workspace, snapshot, stdlib)
        if not cacheIndexedAction(snapshot, options, stdlib, actionCache).handled:
          discard enqueueSemantic(snapshot, options, pending, queued)
        scheduleBootstrap(bootstrap, workspace)
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
        let snapshot = workspace.snapshotForDocument(uriText, path)
        publishNativeDiagnostics(workspace, snapshot, stdlib)
        if not cacheIndexedAction(snapshot, options, stdlib, actionCache).handled:
          discard enqueueSemantic(snapshot, options, pending, queued)
        scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didClose":
      let textDocument = valueOrEmpty(params, "textDocument")
      if textDocument.hasKey("uri"):
        let uriText = textDocument["uri"].getStr
        workspace.closeDocument(uriText, uriToPath(uriText))
        clearNativeDiagnostics(uriText)
        scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didSave":
      let textDocument = valueOrEmpty(params, "textDocument")
      if textDocument.hasKey("uri"):
        let uriText = textDocument["uri"].getStr
        let path = uriToPath(uriText)
        if params.hasKey("text") and params["text"].kind == JString:
          discard workspace.changeDocument(uriText, path, params["text"].getStr, -1)
        let snapshot = workspace.snapshotForDocument(uriText, path)
        publishNativeDiagnostics(workspace, snapshot, stdlib)
        if not cacheIndexedAction(snapshot, options, stdlib, actionCache).handled:
          discard enqueueSemantic(snapshot, options, pending, queued)
        scheduleBootstrap(bootstrap, workspace)
    of "workspace/didChangeWatchedFiles":
      let changes = valueOrEmpty(params, "changes")
      if changes.kind == JArray:
        for change in changes.items:
          if change.kind != JObject or not change.hasKey("uri"):
            continue
          let path = uriToPath(change["uri"].getStr)
          let changeType = intOption(change, "type", 2)
          workspace.fileChanged(path, changeType == 3)
        scheduleBootstrap(bootstrap, workspace)
    of "textDocument/definition":
      if hasId:
        var response = definitionResponse(params, workspace)
        if response.needsBootstrap:
          if bootstrap.active:
            pendingDefinitions.add PendingDefinition(id: id, params: params)
          else:
            discard workspace.bootstrapWorkspace()
            response = definitionResponse(params, workspace)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/documentSymbol":
      if hasId:
        sendResponse(id, documentSymbols(params, workspace))
    of "$/cancelRequest":
      discard
    of "textDocument/codeAction":
      if hasId:
        sendResponse(
          id,
          codeActions(params, workspace, stdlib, actionCache, pending, queued, options),
        )
    else:
      if hasId:
        sendError(id, -32601, "method not supported: " & methodName)
  stopSemanticWorker()
  if lspBootstrapBridgeStarted:
    stopBootstrapWorker()
    lspBootstrapBridge.joinThread()
    lspBootstrapBridgeStarted = false
  if lspInputReaderStarted and not exitRequested:
    lspInputReader.joinThread()
  if not exitRequested:
    lspEvents.close()
  if exitRequested:
    quit(if shutdownRequested: 0 else: 1)
