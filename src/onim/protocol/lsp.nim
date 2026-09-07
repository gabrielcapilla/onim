import std/[atomics, json, monotimes, streams, strutils, times, uri]
import std/os except FileId

when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean

import ../features/completion
import ../features/definition
import ../features/hover
import ../features/organize
import ../features/references
import ../features/rename
import ../features/semantic_tokens
import ../features/signature
import ../semantic/native_diagnostics
import ../semantic/worker
import ../session/bootstrap_worker
import ../session/ids
import ../session/module_catalog
import ../session/workspace
import ../index/source_index
import ../index/surfaces
import ../index/symbols
import ../index/types
import ../stdlib/map
import ../syntax/lexer
import ../syntax/imports
import ../syntax/parser

type
  CachedAction = object
    contentGeneration: ContentGeneration
    dependencyGeneration: DependencyGeneration
    configGeneration: ConfigGeneration
    surfaceGeneration: SurfaceGeneration
    useStdPrefix: bool
    edits: seq[ImportEdit]

  SemanticKey = object
    fileId: FileId
    contentGeneration: ContentGeneration
    dependencyGeneration: DependencyGeneration
    configGeneration: ConfigGeneration
    surfaceGeneration: SurfaceGeneration
    useStdPrefix: bool

  LspEventKind = enum
    lspMessageEvent
    lspBootstrapEvent
    lspSemanticEvent
    lspEndEvent

  LspEvent = object
    kind: LspEventKind
    payload: string

  PendingCodeAction = object
    id: JsonNode
    semantic: SemanticKey
    uri: string

  BootstrapRuntime = object
    active: bool
    hasPending: bool
    nextJobGeneration: uint64
    pending: BootstrapRequest

  PendingWorkspaceRequest = object
    id: JsonNode
    params: JsonNode

  PositionIndex = object
    lineStarts: seq[int]

  DiagnosticPublishReason = enum
    diagnosticOpen
    diagnosticEdit
    diagnosticBootstrap

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

proc clearCachedAction(cache: var seq[CachedAction], id: FileId) {.inline.} =
  let slot = id.slot
  if slot < 0 or slot >= cache.len:
    return
  cache[slot] = CachedAction()
  while cache.len > 0 and
      cache[^1].contentGeneration.value == InvalidContentGeneration.value:
    cache.setLen(cache.len - 1)

var lspEvents: Channel[LspEvent]
var lspInputReader: Thread[void]
var lspBootstrapBridge: Thread[void]
var lspInputReaderStarted = false
var lspBootstrapBridgeStarted = false
var lspSemanticBridge: Thread[void]
var lspSemanticBridgeStarted = false
var lspSemanticStopRequested: Atomic[bool]
var lspTraceEnabled = false

type ProcessMemory = object
  residentKb: uint64
  peakResidentKb: uint64

proc processMemory(): ProcessMemory {.inline.} =
  when defined(linux):
    try:
      for line in readFile("/proc/self/status").splitLines:
        let fields = line.splitWhitespace
        if fields.len < 2:
          continue
        case fields[0]
        of "VmRSS:":
          result.residentKb = parseUInt(fields[1])
        of "VmHWM:":
          result.peakResidentKb = parseUInt(fields[1])
        else:
          discard
    except CatchableError:
      discard

proc traceLsp(
    event, uri: string,
    version: int64,
    snapshotId: SnapshotId,
    fileId: FileId,
    contentGeneration: ContentGeneration,
    dependencyGeneration: DependencyGeneration,
    reason, count: int,
) {.inline.} =
  if not lspTraceEnabled:
    return
  stderr.writeLine(
    "onim lsp event=" & event & " uriHash=" & $contentFingerprint(uri) & " version=" &
      $version & " snapshot=" & $uint64(snapshotId) & " file=" & $uint32(fileId) &
      " content=" & $uint64(contentGeneration) & " dependency=" &
      $uint64(dependencyGeneration) & " reason=" & $reason & " count=" & $count
  )

proc traceLspRequest(
    event: string,
    requestId: JsonNode,
    startedAt: MonoTime,
    key: SemanticKey,
    state: string,
) {.inline.} =
  if not lspTraceEnabled:
    return
  let requestHash =
    if requestId == nil:
      0'u64
    else:
      contentFingerprint($requestId)
  let durationNs = (getMonoTime() - startedAt).inNanoseconds
  let memory = processMemory()
  stderr.writeLine(
    "onim lsp request event=" & event & " requestHash=" & $requestHash & " durationNs=" &
      $durationNs & " state=" & state & " worker=" &
      (if lspSemanticBridgeStarted: "active" else: "idle") & " file=" &
      $uint32(key.fileId) & " content=" & $uint64(key.contentGeneration) & " dependency=" &
      $uint64(key.dependencyGeneration) & " surface=" & $uint64(key.surfaceGeneration) &
      " rssKb=" & $memory.residentKb & " peakRssKb=" & $memory.peakResidentKb
  )

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

proc terminateProcessNow(code: int) {.noreturn.} =
  when defined(posix):
    posix.exitnow(cint(code))
  elif defined(windows):
    discard winlean.terminateProcess(winlean.getCurrentProcess(), code)
    quit(code)
  else:
    quit(code)

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

proc isExitPayload(payload: string): bool {.gcsafe.} =
  try:
    let message = parseJson(payload)
    if message == nil or message.kind != JObject or not message.hasKey("method") or
        message["method"].kind != JString or message["method"].getStr != "exit" or
        message.hasKey("id"):
      return false
    if not message.hasKey("params"):
      return true
    let params = message["params"]
    result =
      params != nil and
      (params.kind == JNull or (params.kind == JObject and params.len == 0))
  except CatchableError:
    discard

proc readInputEvents() {.thread, gcsafe.} =
  while true:
    let payload = readMessageText()
    if payload.len == 0:
      lspEvents.send(LspEvent(kind: lspEndEvent))
      break
    let exitPayload = isExitPayload(payload)
    lspEvents.send(LspEvent(kind: lspMessageEvent, payload: payload))
    if exitPayload:
      break

proc bootstrapEventBridge() {.thread, gcsafe.} =
  while true:
    let value = receiveBootstrap()
    lspEvents.send(
      LspEvent(kind: lspBootstrapEvent, payload: encodeBootstrapResult(value))
    )
    if value.kind == bootstrapStopped:
      break

proc semanticEventBridge() {.thread, gcsafe.} =
  while true:
    let value = receiveSemantic()
    if value.failed and not value.fileId.valid and
        lspSemanticStopRequested.load(moRelaxed):
      break
    lspEvents.send(
      LspEvent(kind: lspSemanticEvent, payload: encodeSemanticResult(value))
    )
    if value.failed and not value.fileId.valid:
      break

proc startSemanticBridge(): bool =
  if lspSemanticBridgeStarted:
    return true
  try:
    createThread(lspSemanticBridge, semanticEventBridge)
    lspSemanticBridgeStarted = true
    true
  except CatchableError:
    false

proc parseMessage(payload: string): JsonNode =
  try:
    parseJson(payload)
  except CatchableError:
    nil

proc validRequestId(node: JsonNode): bool {.inline.} =
  node != nil and node.kind in {JInt, JString}

proc validRequestEnvelope(message: JsonNode): bool =
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

proc fullDocumentChange(
    params: JsonNode
): tuple[valid: bool, uri: string, text: string, version: int64] =
  if params == nil or params.kind != JObject or not params.hasKey("textDocument") or
      not params.hasKey("contentChanges"):
    return
  let document = params["textDocument"]
  let changes = params["contentChanges"]
  if document == nil or document.kind != JObject or not document.hasKey("uri") or
      document["uri"].kind != JString or document["uri"].getStr.len == 0 or
      not document.hasKey("version") or document["version"].kind != JInt or
      changes == nil or changes.kind != JArray or changes.len != 1:
    return
  let change = changes[0]
  if change == nil or change.kind != JObject or not change.hasKey("text") or
      change["text"].kind != JString or change.hasKey("range"):
    return
  result.valid = true
  result.uri = document["uri"].getStr
  result.text = change["text"].getStr
  result.version = document["version"].getInt

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

proc validUriValue(node: JsonNode): bool =
  if node == nil or node.kind != JString or node.getStr.len == 0:
    return false
  try:
    uriToPath(node.getStr).len > 0
  except CatchableError:
    false

proc validTextDocumentParams(params: JsonNode): bool =
  if params == nil or params.kind != JObject or not params.hasKey("textDocument"):
    return false
  let document = params["textDocument"]
  document != nil and document.kind == JObject and document.hasKey("uri") and
    validUriValue(document["uri"])

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

proc validMethodForm(methodName: string, hasId: bool): bool =
  case methodName
  of "initialize", "shutdown", "textDocument/definition", "textDocument/typeDefinition",
      "textDocument/references", "textDocument/hover", "textDocument/rename",
      "textDocument/completion", "textDocument/documentSymbol",
      "textDocument/documentHighlight", "textDocument/foldingRange",
      "textDocument/selectionRange", "textDocument/signatureHelp",
      "textDocument/semanticTokens/full", "textDocument/documentLink",
      "textDocument/codeAction", "workspace/symbol":
    hasId
  of "initialized", "textDocument/didOpen", "textDocument/didChange",
      "textDocument/didSave", "textDocument/didClose",
      "workspace/didChangeWatchedFiles", "$/cancelRequest", "exit":
    not hasId
  else:
    true

proc validMethodParams(methodName: string, params: JsonNode): bool =
  case methodName
  of "initialize":
    validInitializeParams(params)
  of "initialized":
    params != nil and params.kind == JObject
  of "textDocument/didOpen":
    validDidOpenParams(params)
  of "textDocument/didChange":
    fullDocumentChange(params).valid
  of "textDocument/didSave":
    validDidSaveParams(params)
  of "textDocument/didClose":
    validTextDocumentParams(params)
  of "workspace/didChangeWatchedFiles":
    validWatchedFileParams(params)
  of "textDocument/definition", "textDocument/typeDefinition", "textDocument/hover",
      "textDocument/completion", "textDocument/documentHighlight",
      "textDocument/signatureHelp":
    validPositionParams(params)
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
  of nativeUndeclaredIdentifier:
    "undeclared identifier: " & diagnostic.name
  of nativeMissingStdlibImport:
    "missing import: " & diagnostic.module
  of nativeMissingProjectImport:
    "missing project import: " & diagnostic.module

proc sendNativeDiagnostics(
    uri, source: string, diagnostics: seq[NativeDiagnostic], version: int64 = -1
) =
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
  if version >= 0:
    params["version"] = %version
  params["diagnostics"] = values
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["method"] = %"textDocument/publishDiagnostics"
  message["params"] = params
  sendMessage(message)

proc publishNativeDiagnostics(
    workspace: Workspace,
    snapshot: WorkspaceSnapshot,
    stdlib: StdlibMap,
    reason: DiagnosticPublishReason,
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
  traceLsp(
    "publishDiagnostics",
    uri,
    snapshot.version,
    snapshot.id,
    snapshot.fileId,
    snapshot.contentGeneration,
    snapshot.dependencyGeneration,
    ord(reason),
    diagnostics.len,
  )
  if diagnostics.len == 0 and workspace.bootstrapState != workspaceBootstrapComplete and
      reason == diagnosticOpen:
    return
  sendNativeDiagnostics(uri, snapshot.text, diagnostics, snapshot.version)

proc clearNativeDiagnostics(uri: string) =
  if uri.len > 0:
    traceLsp(
      "clearDiagnostics", uri, -1, InvalidSnapshotId, InvalidFileId,
      InvalidContentGeneration, InvalidDependencyGeneration, -1, 0,
    )
    sendNativeDiagnostics(uri, "", @[])

proc targetTokenLength(tokens: TokenStore, token: Token): int =
  let byteLength = token.endOffset - token.startOffset
  let text = tokens.tokenText(token)
  if byteLength == text.len:
    return utf16Length(text)
  if byteLength == text.len + 2:
    return utf16Length(text) + 2
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
    let length = targetTokenLength(view.index.parsed.tokens, token)
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

proc typeDefinitionResponse(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJNull()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString:
    return
  let uriText = textDocument["uri"].getStr
  let path = uriToPath(uriText)
  if path.len == 0 or path.toLowerAscii.endsWith(".nimble") or
      path.toLowerAscii.endsWith(".cfg"):
    return
  let source = workspace.snapshotForDocument(uriText, path)
  if not source.valid or source.index == nil:
    return
  let positions = initPositionIndex(source.text)
  let offset = offsetAt(positions, source.text, valueOrEmpty(params, "position"))
  let tokenIndex = tokenAtOffset(source.index.parsed.tokens, offset)
  if tokenIndex < 0:
    return
  let resolution = resolveDefinitionAtToken(workspace, source, tokenIndex)
  if resolution.kind != definitionResolved:
    return
  let declarationView = workspace.indexViewForFile(resolution.target.fileId)
  if not declarationView.valid or declarationView.index == nil:
    return
  let declarationSymbol =
    declarationView.index.symbols.symbolToken(resolution.target.nameToken)
  if declarationSymbol >= 0 and
      declarationView.index.symbols[declarationSymbol].kind == symbolType:
    result =
      definitionLocation(source, uriText, declarationView, resolution.target, positions)
    return

  let declarationSource =
    if resolution.target.fileId.value == source.fileId.value:
      source
    else:
      workspace.snapshotForFile(resolution.target.fileId)
  if not declarationSource.valid or declarationSource.index == nil:
    return
  let localType =
    workspace.resolveLocalType(declarationSource, resolution.target.nameToken)
  if localType.info.state != typeStateResolved or
      source.index.types.namedTypeId(localType.info.typeId) == InvalidTypeId or
      localType.info.typeToken == InvalidTypeToken:
    return
  let typeSource =
    if localType.fileId.value == declarationSource.fileId.value:
      declarationSource
    else:
      workspace.snapshotForFile(localType.fileId)
  if not typeSource.valid or typeSource.index == nil or
      typeSource.id.value != localType.snapshotId.value or
      typeSource.contentGeneration.value != localType.contentGeneration.value:
    return
  let typeResolution =
    resolveDefinitionAtToken(workspace, typeSource, int(localType.info.typeToken))
  if typeResolution.kind != definitionResolved:
    return
  let typeView = workspace.indexViewForFile(typeResolution.target.fileId)
  result =
    definitionLocation(source, uriText, typeView, typeResolution.target, positions)

proc referenceLocation(
    uri: string, source: WorkspaceSnapshot, token: Token, positions: PositionIndex
): JsonNode =
  if token.startOffset < 0 or token.endOffset < token.startOffset or
      token.endOffset > source.text.len:
    return
  %*{
    "uri": uri,
    "range": {
      "start": positionAt(positions, source.text, token.startOffset),
      "end": positionAt(positions, source.text, token.endOffset),
    },
  }

proc appendReferenceLocations(
    values: JsonNode,
    workspace: Workspace,
    source: WorkspaceSnapshot,
    sourceUri: string,
    matches: openArray[ReferenceMatch],
): bool =
  var currentFile = InvalidFileId
  var currentGeneration = InvalidContentGeneration
  var currentSource: WorkspaceSnapshot
  var currentUri = ""
  var positions: PositionIndex
  for match in matches:
    if match.fileId.value != currentFile.value:
      currentFile = match.fileId
      currentSource =
        if match.fileId.value == source.fileId.value:
          source
        else:
          workspace.snapshotForFile(match.fileId)
      if not currentSource.valid or currentSource.index == nil:
        return false
      currentGeneration = currentSource.contentGeneration
      if currentGeneration.value != match.contentGeneration.value:
        return false
      currentUri =
        if match.fileId.value == source.fileId.value:
          sourceUri
        elif currentSource.uri.len > 0:
          currentSource.uri
        else:
          fileUri(currentSource.path)
      positions = initPositionIndex(currentSource.text)
    elif currentGeneration.value != match.contentGeneration.value:
      return false
    if match.tokenIndex >= uint32(currentSource.index.parsed.tokens.len):
      return false
    let location = referenceLocation(
      currentUri,
      currentSource,
      currentSource.index.parsed.tokens[int(match.tokenIndex)],
      positions,
    )
    if location == nil:
      return false
    values.add location
  true

proc bootstrapPending(workspace: Workspace): bool {.inline.} =
  workspace != nil and workspace.root.len > 0 and
    workspace.bootstrapState in {
      workspaceBootstrapPending, workspaceBootstrapIncomplete
    }

proc referencesResponse(
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
  let context = valueOrEmpty(params, "context")
  let includeDeclaration =
    context.kind == JObject and context.hasKey("includeDeclaration") and
    context["includeDeclaration"].kind == JBool and context["includeDeclaration"].getBool
  let references = resolveReferences(workspace, snapshot, offset, includeDeclaration)
  if not references.supported:
    result.needsBootstrap = workspace.bootstrapPending
    return
  result.value = newJArray()
  if not appendReferenceLocations(
    result.value, workspace, snapshot, uriText, references.matches
  ):
    result.value = newJNull()

proc hoverResponse(
    params: JsonNode, workspace: Workspace, stdlib: StdlibMap
): JsonNode =
  result = newJNull()
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
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let info = resolveHover(workspace, snapshot, offset, stdlib)
  if info.state != hoverAvailable:
    return
  let tokenIndex = tokenAtOffset(snapshot.index.parsed.tokens, offset)
  if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
    return
  let token = snapshot.index.parsed.tokens[tokenIndex]
  var value = "```nim\n"
  if info.signature.len > 0:
    value.add info.signature
  elif info.kind.len > 0:
    value.add info.kind & " " & info.name
  else:
    value.add info.name
  if info.module.len > 0:
    value.add "\n# " & info.module
  value.add "\n```"
  result = %*{
    "contents": {"kind": "markdown", "value": value},
    "range": {
      "start": positionAt(positions, snapshot.text, token.startOffset),
      "end": positionAt(positions, snapshot.text, token.endOffset),
    },
  }

proc signatureHelpResponse(
    params: JsonNode, workspace: Workspace, stdlib: StdlibMap
): JsonNode =
  result = newJNull()
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
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let info = resolveSignatureHelp(workspace, snapshot, offset, stdlib)
  if info.state != signatureAvailable:
    return
  var signatures = newJArray()
  for signature in info.signatures:
    var parameters = newJArray()
    for parameter in signature.parameters:
      parameters.add %*{"label": parameter}
    signatures.add %*{"label": signature.label, "parameters": parameters}
  if signatures.len == 0:
    return
  result = %*{
    "signatures": signatures,
    "activeSignature": 0,
    "activeParameter": info.activeParameter,
  }

proc semanticTokensResponse(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJObject()
  result["data"] = newJArray()
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
  var previousLine = 0
  var previousStart = 0
  for item in semanticTokens(snapshot.index):
    if item.token >= uint32(snapshot.index.parsed.tokens.len):
      continue
    let token = snapshot.index.parsed.tokens[int(item.token)]
    if token.startOffset < 0 or token.endOffset <= token.startOffset or
        token.endOffset > snapshot.text.len:
      continue
    let start = positionAt(positions, snapshot.text, token.startOffset)
    let finish = positionAt(positions, snapshot.text, token.endOffset)
    let line = start["line"].getInt
    let character = start["character"].getInt
    if finish["line"].getInt != line:
      continue
    let length = finish["character"].getInt - character
    if length <= 0:
      continue
    let deltaLine = line - previousLine
    let deltaStart =
      if deltaLine == 0:
        character - previousStart
      else:
        character
    result["data"].add %deltaLine
    result["data"].add %deltaStart
    result["data"].add %length
    result["data"].add %ord(item.kind)
    result["data"].add %0
    previousLine = line
    previousStart = character

proc appendRenameEdits(
    changes: JsonNode,
    workspace: Workspace,
    source: WorkspaceSnapshot,
    sourceUri, newName: string,
    matches: openArray[ReferenceMatch],
): bool =
  var currentFile = InvalidFileId
  var currentSource: WorkspaceSnapshot
  var currentUri = ""
  var positions: PositionIndex
  var previousEnd = -1
  for match in matches:
    if match.fileId.value != currentFile.value:
      currentFile = match.fileId
      currentSource =
        if match.fileId.value == source.fileId.value:
          source
        else:
          workspace.snapshotForFile(match.fileId)
      if not currentSource.valid or currentSource.index == nil or
          currentSource.id.value != source.id.value or
          currentSource.contentGeneration.value != match.contentGeneration.value or
          currentSource.index.contentHash != contentFingerprint(currentSource.text) or
          currentSource.index.byteLength != currentSource.text.len:
        return false
      currentUri =
        if match.fileId.value == source.fileId.value:
          sourceUri
        elif currentSource.uri.len > 0:
          currentSource.uri
        else:
          fileUri(currentSource.path)
      if currentUri.len == 0 or changes.hasKey(currentUri):
        return false
      changes[currentUri] = newJArray()
      positions = initPositionIndex(currentSource.text)
      previousEnd = -1
    elif currentSource.contentGeneration.value != match.contentGeneration.value:
      return false
    if match.tokenIndex >= uint32(currentSource.index.parsed.tokens.len):
      return false
    let token = currentSource.index.parsed.tokens[int(match.tokenIndex)]
    if token.kind != tkIdentifier or not validIdentifier(token) or token.startOffset < 0 or
        token.endOffset <= token.startOffset or token.endOffset > currentSource.text.len or
        token.startOffset < previousEnd:
      return false
    changes[currentUri].add %*{
      "range": {
        "start": positionAt(positions, currentSource.text, token.startOffset),
        "end": positionAt(positions, currentSource.text, token.endOffset),
      },
      "newText": newName,
    }
    previousEnd = token.endOffset
  true

proc renameResponse(
    params: JsonNode, workspace: Workspace
): tuple[value: JsonNode, needsBootstrap: bool] =
  result.value = newJNull()
  let textDocument = valueOrEmpty(params, "textDocument")
  if textDocument.kind != JObject or not textDocument.hasKey("uri") or
      textDocument["uri"].kind != JString or not params.hasKey("newName") or
      params["newName"].kind != JString:
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
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let info = resolveRename(workspace, snapshot, offset, params["newName"].getStr)
  if info.state != renameAvailable:
    result.needsBootstrap = workspace.bootstrapPending
    return
  var changes = newJObject()
  if not appendRenameEdits(
    changes, workspace, snapshot, uriText, params["newName"].getStr, info.matches
  ):
    return
  result.value = %*{"changes": changes}

proc completionItemKind(kind: CompletionKind): int {.inline.} =
  case kind
  of completionVariable: 6
  of completionConstant: 21
  of completionFunction: 3
  of completionMethod: 2
  of completionField: 5
  of completionType: 7

proc completionResponse(
    params: JsonNode, workspace: Workspace, stdlib: StdlibMap
): JsonNode =
  result = newJNull()
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
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  let completion = completeAt(workspace, snapshot, offset, stdlib)
  if completion.state != completionAvailable:
    return
  let start = positionAt(positions, snapshot.text, completion.replaceStart)
  let finish = positionAt(positions, snapshot.text, completion.replaceEnd)
  var items = newJArray()
  for item in completion.items:
    items.add %*{
      "label": item.label,
      "kind": completionItemKind(item.kind),
      "textEdit": {"range": {"start": start, "end": finish}, "newText": item.label},
    }
  result = %*{"isIncomplete": true, "items": items}

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
      "name": snapshot.index.parsed.tokens.tokenText(token),
      "kind": documentSymbolKind(symbol.kind),
      "range": {"start": start, "end": finish},
      "selectionRange": {"start": start, "end": finish},
    }

proc workspaceSymbols(params: JsonNode, workspace: Workspace): JsonNode =
  result = newJArray()
  let query = identifierKey(params["query"].getStr)
  for fileId in workspace.fileIds:
    let snapshot = workspace.snapshotForFile(fileId)
    if not snapshot.valid or snapshot.index == nil or
        snapshot.path.toLowerAscii.endsWith(".nimble") or
        snapshot.path.toLowerAscii.endsWith(".cfg"):
      continue
    let positions = initPositionIndex(snapshot.text)
    let uriText =
      if snapshot.uri.len > 0:
        snapshot.uri
      else:
        fileUri(snapshot.path)
    for symbol in snapshot.index.symbols:
      let tokenIndex = int(symbol.nameToken)
      if tokenIndex < 0 or tokenIndex >= snapshot.index.parsed.tokens.len:
        continue
      let token = snapshot.index.parsed.tokens[tokenIndex]
      if token.kind != tkIdentifier or token.startOffset < 0 or
          token.endOffset > snapshot.text.len or token.endOffset <= token.startOffset:
        continue
      let name = snapshot.index.parsed.tokens.tokenText(token)
      if query.len > 0 and query notin identifierKey(name):
        continue
      let start = positionAt(positions, snapshot.text, token.startOffset)
      let finish = positionAt(positions, snapshot.text, token.endOffset)
      result.add %*{
        "name": name,
        "kind": documentSymbolKind(symbol.kind),
        "location": {"uri": uriText, "range": {"start": start, "end": finish}},
      }

proc addDocumentLink(
    links: var JsonNode,
    workspace: Workspace,
    source: WorkspaceSnapshot,
    positions: PositionIndex,
    item: ImportInfo,
): bool =
  if workspace == nil or not source.valid or source.index == nil or item.synthetic or
      item.conditional or item.module.len == 0 or item.moduleStartOffset < 0 or
      item.moduleEndOffset <= item.moduleStartOffset or
      item.moduleEndOffset > source.text.len:
    return
  let catalog = workspace.moduleCatalog()
  if catalog == nil or not catalog.complete:
    return
  let resolved =
    catalog.resolveModuleName(workspace.moduleForPath(source.path), item.module)
  if resolved.kind != moduleResolved:
    return
  let targetId = workspace.resolveModule(source.fileId, item.module)
  if not targetId.valid or targetId.value != resolved.id.value:
    return
  let target = workspace.indexViewForFile(targetId)
  if not target.valid or target.path.len == 0:
    return
  let targetUri =
    if target.uri.len > 0:
      target.uri
    else:
      fileUri(target.path)
  if targetUri.len == 0:
    return
  links.add %*{
    "range": {
      "start": positionAt(positions, source.text, item.moduleStartOffset),
      "end": positionAt(positions, source.text, item.moduleEndOffset),
    },
    "target": targetUri,
  }
  true

proc documentLinks(params: JsonNode, workspace: Workspace): JsonNode =
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
  for item in snapshot.index.parsed.imports:
    discard addDocumentLink(result, workspace, snapshot, positions, item)
  for node in snapshot.index.syntax.nodes:
    if node.kind != syntaxInclude or node.uncertainty != {}:
      continue
    let parsed = parseIncludeReferences(
      snapshot.index.parsed.tokens, snapshot.text, int(node.firstToken)
    )
    if parsed.uncertainty != {} or parsed.next != int(node.pastToken):
      continue
    for item in parsed.references:
      discard addDocumentLink(result, workspace, snapshot, positions, item)

proc documentHighlights(params: JsonNode, workspace: Workspace): JsonNode =
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
  let offset = offsetAt(positions, snapshot.text, valueOrEmpty(params, "position"))
  if offset < 0:
    return
  let references = resolveSameFileReferences(workspace, snapshot, offset, true)
  if not references.supported:
    return
  for tokenIndex in references.tokens:
    if tokenIndex >= uint32(snapshot.index.parsed.tokens.len):
      continue
    let token = snapshot.index.parsed.tokens[int(tokenIndex)]
    if token.startOffset < 0 or token.endOffset <= token.startOffset or
        token.endOffset > snapshot.text.len:
      continue
    result.add %*{
      "range": {
        "start": positionAt(positions, snapshot.text, token.startOffset),
        "end": positionAt(positions, snapshot.text, token.endOffset),
      },
      "kind": 1,
    }

proc foldingRanges(params: JsonNode, workspace: Workspace): JsonNode =
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
  for node in snapshot.index.syntax.nodes:
    if node.kind notin {syntaxWhen, syntaxBlock, syntaxDeclaration} or
        node.uncertainty != {}:
      continue
    let first = int(node.firstToken)
    let past = int(node.pastToken)
    if first < 0 or past <= first or past > snapshot.index.parsed.tokens.len:
      continue
    let startLine = snapshot.index.parsed.tokens[first].line
    let endLine = snapshot.index.parsed.tokens[past - 1].line
    if startLine < 0 or endLine <= startLine:
      continue
    result.add %*{"startLine": startLine, "endLine": endLine}

proc selectionRangeItem(
    source: string, positions: PositionIndex, startOffset, endOffset: int
): JsonNode =
  %*{
    "start": positionAt(positions, source, startOffset),
    "end": positionAt(positions, source, endOffset),
  }

proc selectionRanges(params: JsonNode, workspace: Workspace): JsonNode =
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
  for position in params["positions"].items:
    let offset = offsetAt(positions, snapshot.text, position)
    if offset < 0:
      continue
    var spans: seq[tuple[startOffset, endOffset: int]] = @[]
    let tokenIndex = tokenContaining(snapshot.index.parsed.tokens, offset, offset)
    if tokenIndex >= 0:
      let token = snapshot.index.parsed.tokens[tokenIndex]
      spans.add (token.startOffset, token.endOffset)
      var nodeIndex = -1
      for candidateIndex, node in snapshot.index.syntax.nodes:
        if candidateIndex == 0 or node.firstToken > uint32(tokenIndex) or
            node.pastToken <= uint32(tokenIndex):
          continue
        if nodeIndex < 0 or
            node.pastToken - node.firstToken <
            snapshot.index.syntax.nodes[nodeIndex].pastToken -
            snapshot.index.syntax.nodes[nodeIndex].firstToken:
          nodeIndex = candidateIndex
      while nodeIndex > 0 and nodeIndex < snapshot.index.syntax.nodes.len:
        let node = snapshot.index.syntax.nodes[nodeIndex]
        let first = int(node.firstToken)
        let past = int(node.pastToken)
        if first >= 0 and past > first and past <= snapshot.index.parsed.tokens.len:
          spans.add (
            snapshot.index.parsed.tokens[first].startOffset,
            snapshot.index.parsed.tokens[past - 1].endOffset,
          )
        let parent = int(uint32(node.parent)) - 1
        if parent <= 0 or parent >= snapshot.index.syntax.nodes.len:
          break
        nodeIndex = parent
    if spans.len == 0:
      spans.add (0, snapshot.text.len)
    elif spans[^1].startOffset != 0 or spans[^1].endOffset != snapshot.text.len:
      spans.add (0, snapshot.text.len)
    var parent: JsonNode
    for spanIndex in countdown(spans.high, 0):
      var item = newJObject()
      item["range"] = selectionRangeItem(
        snapshot.text,
        positions,
        spans[spanIndex].startOffset,
        spans[spanIndex].endOffset,
      )
      if parent != nil:
        item["parent"] = parent
      parent = item
    result.add parent

proc editJson(source: string, positions: PositionIndex, edit: ImportEdit): JsonNode =
  %*{
    "range": {
      "start": positionAt(positions, source, edit.startOffset),
      "end": positionAt(positions, source, edit.endOffset),
    },
    "newText": edit.newText,
  }

proc renderCodeActions(uriText, source: string, edits: seq[ImportEdit]): JsonNode =
  if edits.len == 0:
    return newJArray()
  let positions = initPositionIndex(source)
  var uriEdits = newJArray()
  for edit in edits:
    uriEdits.add editJson(source, positions, edit)
  var workspaceEdit = newJObject()
  workspaceEdit["changes"] = newJObject()
  workspaceEdit["changes"][uriText] = uriEdits
  var action = newJObject()
  action["title"] = %"Organize Nim imports"
  action["kind"] = %"source.organizeImports"
  action["edit"] = workspaceEdit
  result = newJArray()
  result.add action

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
  if params == nil or params.kind != JObject or not params.hasKey("context"):
    return true
  let context = params["context"]
  if context == nil or context.kind != JObject or not context.hasKey("only"):
    return true
  let only = context["only"]
  if only == nil or only.kind != JArray:
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
    surfaceGeneration: snapshot.surfaceGeneration,
    useStdPrefix: options.useStdPrefix,
  )

proc semanticKey(value: SemanticResult): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    surfaceGeneration: value.surfaceGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc semanticKey(value: SemanticRequest): SemanticKey =
  SemanticKey(
    fileId: value.fileId,
    contentGeneration: value.contentGeneration,
    dependencyGeneration: value.dependencyGeneration,
    configGeneration: value.configGeneration,
    surfaceGeneration: value.surfaceGeneration,
    useStdPrefix: value.useStdPrefix,
  )

proc sameSemanticKey(left, right: SemanticKey): bool =
  left.fileId.value == right.fileId.value and
    left.contentGeneration.value == right.contentGeneration.value and
    left.dependencyGeneration.value == right.dependencyGeneration.value and
    left.configGeneration.value == right.configGeneration.value and
    left.surfaceGeneration.value == right.surfaceGeneration.value and
    left.useStdPrefix == right.useStdPrefix

proc removePending(pending: var SemanticKey, key: SemanticKey) =
  if pending.fileId.valid and sameSemanticKey(pending, key):
    pending = SemanticKey()

proc removeQueued(queued: var seq[SemanticRequest], fileId: FileId) =
  var writeIndex = 0
  for request in queued:
    if request.fileId.value != fileId.value:
      queued[writeIndex] = request
      inc writeIndex
  queued.setLen(writeIndex)

proc removeQueued(queued: var seq[SemanticRequest], key: SemanticKey) =
  var writeIndex = 0
  for request in queued:
    if not sameSemanticKey(semanticKey(request), key):
      queued[writeIndex] = request
      inc writeIndex
  queued.setLen(writeIndex)

proc queueSemantic(queued: var seq[SemanticRequest], request: SemanticRequest) =
  removeQueued(queued, request.fileId)
  queued.add request

proc dispatchSemantic(
    queued: var seq[SemanticRequest], pending: var SemanticKey
): bool =
  if pending.fileId.valid or queued.len == 0:
    return false
  let request = queued[0]
  if not startSemanticWorker():
    return false
  if not submitSemantic(request):
    stopSemanticWorker()
    finishSemanticWorkerStop()
    return false
  if not startSemanticBridge():
    stopSemanticWorker()
    finishSemanticWorkerStop()
    return false
  queued.delete(0)
  pending = semanticKey(request)
  true

proc actionIsCurrent(
    action: CachedAction, snapshot: WorkspaceSnapshot, options: OrganizeOptions
): bool =
  action.contentGeneration.value == snapshot.contentGeneration.value and
    action.dependencyGeneration.value == snapshot.dependencyGeneration.value and
    action.configGeneration.value == snapshot.configGeneration.value and
    action.surfaceGeneration.value == snapshot.surfaceGeneration.value and
    action.useStdPrefix == options.useStdPrefix

proc enqueueSemantic(
    snapshot: WorkspaceSnapshot,
    options: OrganizeOptions,
    pending: var SemanticKey,
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
    surfaceGeneration: snapshot.surfaceGeneration,
    useStdPrefix: options.useStdPrefix,
  )
  let key = semanticKey(request)
  if pending.fileId.valid and sameSemanticKey(pending, key):
    return true
  queueSemantic(queued, request)
  if not pending.fileId.valid and not dispatchSemantic(queued, pending):
    removeQueued(queued, request.fileId)
    return false
  true

proc cacheIndexedAction(
    workspace: Workspace,
    snapshot: WorkspaceSnapshot,
    options: OrganizeOptions,
    stdlib: var StdlibMap,
    actionCache: var seq[CachedAction],
): tuple[handled: bool, edits: seq[ImportEdit]] =
  if not snapshot.valid:
    return
  if stdlib == nil:
    stdlib = stdlibMap()
  var project: SurfaceIndex
  var catalog: ModuleCatalog
  var owner = ""
  if workspace.graphComplete:
    project = workspace.projectSurface()
    catalog = workspace.moduleCatalog()
    owner = workspace.moduleForPath(snapshot.path)
  let attempt = tryOrganizeSourceWithIndex(
    snapshot.path, snapshot.text, snapshot.index, stdlib, options, project, catalog,
    owner,
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
      surfaceGeneration: snapshot.surfaceGeneration,
      useStdPrefix: options.useStdPrefix,
      edits: result.edits,
    ),
  )

proc acceptSemantic(
    value: SemanticResult,
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
) =
  if value.failed:
    if value.fileId.valid:
      removePending(pending, semanticKey(value))
      discard dispatchSemantic(queued, pending)
    else:
      pending = SemanticKey()
      queued.setLen(0)
    return
  if not value.fileId.valid:
    pending = SemanticKey()
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
        surfaceGeneration: value.surfaceGeneration,
        useStdPrefix: value.useStdPrefix,
        edits: value.edits,
      ),
    )
  discard dispatchSemantic(queued, pending)

proc finishPendingCodeActionsForUri(pending: var seq[PendingCodeAction], uri: string) =
  var completed: seq[PendingCodeAction] = @[]
  var writeIndex = 0
  for item in pending:
    if item.uri == uri:
      completed.add item
    else:
      pending[writeIndex] = item
      inc writeIndex
  pending.setLen(writeIndex)
  for item in completed:
    sendResponse(item.id, newJArray())

proc finishPendingCodeActions(
    pending: var seq[PendingCodeAction],
    workspace: Workspace,
    actionCache: seq[CachedAction],
    value: SemanticResult,
): bool =
  let terminal = value.failed and not value.fileId.valid
  let key = semanticKey(value)
  var completed: seq[PendingCodeAction] = @[]
  var writeIndex = 0
  for item in pending:
    if terminal or sameSemanticKey(item.semantic, key):
      completed.add item
    else:
      pending[writeIndex] = item
      inc writeIndex
  pending.setLen(writeIndex)
  for item in completed:
    if not terminal:
      let snapshot = workspace.snapshotForFile(item.semantic.fileId)
      if snapshot.valid and hasCachedAction(actionCache, item.semantic.fileId) and
          actionIsCurrent(
            cachedActionFor(actionCache, item.semantic.fileId),
            snapshot,
            OrganizeOptions(useStdPrefix: item.semantic.useStdPrefix),
          ):
        sendResponse(
          item.id,
          renderCodeActions(
            item.uri,
            snapshot.text,
            cachedActionFor(actionCache, item.semantic.fileId).edits,
          ),
        )
        continue
    sendResponse(item.id, newJArray())
  terminal

proc refreshPendingCodeActions(
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

proc sameRequestId(left, right: JsonNode): bool =
  left != nil and right != nil and left.kind == right.kind and left == right

proc cancelPendingCodeAction(
    pending: var seq[PendingCodeAction],
    queued: var seq[SemanticRequest],
    active: var SemanticKey,
    requestId: JsonNode,
): tuple[found: bool, stopWorker: bool] =
  for index, item in pending:
    if sameRequestId(item.id, requestId):
      let key = item.semantic
      pending.delete(index)
      sendError(item.id, -32800, "Request cancelled")
      for other in pending:
        if sameSemanticKey(other.semantic, key):
          result.found = true
          return
      removeQueued(queued, key)
      if active.fileId.valid and sameSemanticKey(active, key) and queued.len == 0:
        active = SemanticKey()
        result.stopWorker = true
      result.found = true
      return

proc cancelPendingWorkspaceRequest(
    pending: var seq[PendingWorkspaceRequest], requestId: JsonNode
): bool =
  for index, item in pending:
    if sameRequestId(item.id, requestId):
      let id = item.id
      pending.delete(index)
      sendError(id, -32800, "Request cancelled")
      return true
  false

proc cancelPendingCodeActions(pending: var seq[PendingCodeAction]) =
  for item in pending:
    sendError(item.id, -32800, "Request cancelled")
  pending.setLen(0)

proc cancelPendingWorkspaceRequests(pending: var seq[PendingWorkspaceRequest]) =
  for item in pending:
    sendError(item.id, -32800, "Request cancelled")
  pending.setLen(0)

proc handleSemanticEvent(
    payload: string,
    workspace: Workspace,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
    pendingCodeActions: var seq[PendingCodeAction],
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
    discard finishPendingCodeActions(pendingCodeActions, workspace, actionCache, value)
  result = not pending.fileId.valid and queued.len == 0

proc codeActionOutcome(
    params: JsonNode,
    workspace: Workspace,
    stdlib: var StdlibMap,
    actionCache: var seq[CachedAction],
    pending: var SemanticKey,
    queued: var seq[SemanticRequest],
    options: OrganizeOptions,
): tuple[response: JsonNode, deferred: bool, key: SemanticKey, uri: string] =
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
      if enqueueSemantic(snapshot, options, pending, queued):
        result.deferred = true
        result.uri = uriText
        return
  result.response = renderCodeActions(uriText, snapshot.text, edits)

proc scheduleBootstrap(runtime: var BootstrapRuntime, workspace: Workspace): bool =
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
    return true
  elif submitBootstrap(request):
    runtime.active = true
    return true
  false

proc publishOpenNativeDiagnostics(workspace: Workspace, stdlib: StdlibMap) =
  for id in workspace.openDocumentIds:
    let snapshot = workspace.snapshotForFile(id)
    publishNativeDiagnostics(workspace, snapshot, stdlib, diagnosticBootstrap)

proc finishPendingDefinitions(
    workspace: Workspace, pending: var seq[PendingWorkspaceRequest]
) =
  for item in pending:
    let response = definitionResponse(item.params, workspace)
    if response.needsBootstrap:
      sendResponse(item.id, newJNull())
    else:
      sendResponse(item.id, response.value)
  pending.setLen(0)

proc finishPendingReferences(
    workspace: Workspace, pending: var seq[PendingWorkspaceRequest]
) =
  for item in pending:
    let response = referencesResponse(item.params, workspace)
    if response.needsBootstrap:
      sendResponse(item.id, newJNull())
    else:
      sendResponse(item.id, response.value)
  pending.setLen(0)

proc finishPendingRenames(
    workspace: Workspace, pending: var seq[PendingWorkspaceRequest]
) =
  for item in pending:
    let response = renameResponse(item.params, workspace)
    if response.needsBootstrap:
      sendResponse(item.id, newJNull())
    else:
      sendResponse(item.id, response.value)
  pending.setLen(0)

proc handleBootstrapEvent(
    runtime: var BootstrapRuntime,
    workspace: Workspace,
    pendingDefinitions: var seq[PendingWorkspaceRequest],
    pendingReferences: var seq[PendingWorkspaceRequest],
    pendingRenames: var seq[PendingWorkspaceRequest],
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
    finishPendingReferences(workspace, pendingReferences)
    finishPendingRenames(workspace, pendingRenames)
  elif value.kind == bootstrapFailed:
    finishPendingDefinitions(workspace, pendingDefinitions)
    finishPendingReferences(workspace, pendingReferences)
    finishPendingRenames(workspace, pendingRenames)
  if runtime.hasPending:
    let request = runtime.pending
    runtime.hasPending = false
    if submitBootstrap(request):
      runtime.active = true
  accepted

proc runLsp*() =
  lspTraceEnabled = getEnv("ONIM_TRACE_LSP").len > 0
  let workspace = initWorkspace()
  var stdlib = stdlibMap()
  var actionCache: seq[CachedAction] = @[]
  var pending: SemanticKey
  var queued: seq[SemanticRequest] = @[]
  var pendingDefinitions: seq[PendingWorkspaceRequest] = @[]
  var pendingReferences: seq[PendingWorkspaceRequest] = @[]
  var pendingRenames: seq[PendingWorkspaceRequest] = @[]
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
    if event.kind == lspEndEvent:
      break
    if event.kind == lspBootstrapEvent:
      if shutdownRequested:
        continue
      if decodeBootstrapResult(event.payload).kind != bootstrapStopped:
        discard handleBootstrapEvent(
          bootstrap, workspace, pendingDefinitions, pendingReferences, pendingRenames,
          stdlib, event.payload,
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
      capabilities["typeDefinitionProvider"] = %true
      capabilities["completionProvider"] = %*{"resolveProvider": false}
      capabilities["hoverProvider"] = %true
      capabilities["renameProvider"] = %*{"prepareProvider": false}
      capabilities["referencesProvider"] = %true
      capabilities["documentSymbolProvider"] = %true
      capabilities["documentHighlightProvider"] = %true
      capabilities["foldingRangeProvider"] = %true
      capabilities["selectionRangeProvider"] = %true
      capabilities["documentLinkProvider"] = %*{"resolveProvider": false}
      capabilities["signatureHelpProvider"] =
        %*{"triggerCharacters": ["(", ","], "retriggerCharacters": [","]}
      var semanticTokenTypes = newJArray()
      for kind in SemanticTokenKind:
        semanticTokenTypes.add %semanticTokenTypeNames[kind]
      capabilities["semanticTokensProvider"] = %*{
        "legend": {"tokenTypes": semanticTokenTypes, "tokenModifiers": []}, "full": true
      }
      capabilities["workspaceSymbolProvider"] = %true
      capabilities["positionEncoding"] = %"utf-16"
      var result = newJObject()
      result["capabilities"] = capabilities
      result["serverInfo"] = %*{"name": "onim", "version": "0.1.0"}
      sendResponse(id, result)
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
      cancelPendingWorkspaceRequests(pendingDefinitions)
      cancelPendingWorkspaceRequests(pendingReferences)
      cancelPendingWorkspaceRequests(pendingRenames)
      pending = SemanticKey()
      queued.setLen(0)
      sendResponse(id, newJNull())
    of "exit":
      discard
    of "textDocument/didOpen":
      let textDocument = params["textDocument"]
      let uriText = textDocument["uri"].getStr
      let path = uriToPath(uriText)
      if not workspace.isOpenDocument(path):
        let fileId = workspace.openDocument(
          uriText, path, textDocument["text"].getStr, textDocument["version"].getInt
        )
        if fileId.valid:
          let snapshot = workspace.snapshotForDocument(uriText, path)
          if snapshot.valid:
            finishPendingCodeActionsForUri(pendingCodeActions, uriText)
            publishNativeDiagnostics(workspace, snapshot, stdlib, diagnosticOpen)
            if not cacheIndexedAction(workspace, snapshot, options, stdlib, actionCache).handled:
              discard enqueueSemantic(snapshot, options, pending, queued)
            discard scheduleBootstrap(bootstrap, workspace)
    of "textDocument/didChange":
      let change = fullDocumentChange(params)
      if change.valid:
        let path = uriToPath(change.uri)
        if workspace.isOpenDocument(path):
          let before = workspace.snapshotForFile(workspace.fileIdForPath(path))
          if workspace.changeDocument(change.uri, path, change.text, change.version):
            let snapshot = workspace.snapshotForDocument(change.uri, path)
            if before.contentGeneration.value != snapshot.contentGeneration.value:
              finishPendingCodeActionsForUri(pendingCodeActions, change.uri)
              publishNativeDiagnostics(workspace, snapshot, stdlib, diagnosticEdit)
              if not cacheIndexedAction(
                workspace, snapshot, options, stdlib, actionCache
              ).handled:
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
        clearNativeDiagnostics(uriText)
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
            publishNativeDiagnostics(workspace, snapshot, stdlib, diagnosticEdit)
            if not cacheIndexedAction(workspace, snapshot, options, stdlib, actionCache).handled:
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
            pendingDefinitions.add PendingWorkspaceRequest(id: id, params: params)
          else:
            discard workspace.bootstrapWorkspace()
            response = definitionResponse(params, workspace)
            sendResponse(id, response.value)
        else:
          sendResponse(id, response.value)
    of "textDocument/typeDefinition":
      if hasId:
        sendResponse(id, typeDefinitionResponse(params, workspace))
    of "textDocument/references":
      if hasId:
        let response = referencesResponse(params, workspace)
        if response.needsBootstrap:
          pendingReferences.add PendingWorkspaceRequest(id: id, params: params)
          if not bootstrap.active:
            if not scheduleBootstrap(bootstrap, workspace):
              pendingReferences.setLen(pendingReferences.len - 1)
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
          pendingRenames.add PendingWorkspaceRequest(id: id, params: params)
          if not bootstrap.active:
            if not scheduleBootstrap(bootstrap, workspace):
              pendingRenames.setLen(pendingRenames.len - 1)
              sendResponse(id, newJNull())
        else:
          sendResponse(id, response.value)
    of "textDocument/completion":
      if hasId:
        sendResponse(id, completionResponse(params, workspace, stdlib))
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
        if not cancelPendingWorkspaceRequest(pendingDefinitions, requestId):
          if not cancelPendingWorkspaceRequest(pendingReferences, requestId):
            discard cancelPendingWorkspaceRequest(pendingRenames, requestId)
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
          "codeAction",
          id,
          startedAt,
          outcome.key,
          if outcome.deferred: "deferred" else: "ready",
        )
        if outcome.key.fileId.valid:
          finishPendingCodeActionsForUri(pendingCodeActions, outcome.uri)
        if outcome.deferred:
          pendingCodeActions.add PendingCodeAction(
            id: id, semantic: outcome.key, uri: outcome.uri
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
