import std/[json, os, streams, strutils, tables, uri]

import ./organize

type DocumentStore = Table[string, string]

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

proc documentText(documents: DocumentStore, uriText: string): string =
  if documents.hasKey(uriText):
    return documents[uriText]
  let path = uriToPath(uriText)
  if path.len > 0 and fileExists(path):
    try:
      return readFile(path)
    except CatchableError:
      discard
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

proc codeActions(
    params: JsonNode, documents: DocumentStore, options: OrganizeOptions
): JsonNode =
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
  let source = documentText(documents, uriText)
  if source.len == 0 and (path.len == 0 or not fileExists(path)):
    return newJArray()
  let edits = organizeSource(path, source, options)
  if edits.len == 0:
    return newJArray()
  var workspaceEdit = newJObject()
  var uriEdits = newJArray()
  for edit in edits:
    uriEdits.add editJson(source, edit)
  workspaceEdit["changes"] = newJObject()
  workspaceEdit["changes"][uriText] = uriEdits
  var action = newJObject()
  action["title"] = %"Organize Nim imports"
  action["kind"] = %"source.organizeImports"
  action["edit"] = workspaceEdit
  result = newJArray()
  result.add action

proc runLsp*() =
  var documents = initTable[string, string]()
  var options = defaultOrganizeOptions()
  var shutdownRequested = false
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
      quit(if shutdownRequested: 0 else: 1)
    of "textDocument/didOpen":
      let textDocument = valueOrEmpty(params, "textDocument")
      if textDocument.hasKey("uri") and textDocument.hasKey("text"):
        documents[textDocument["uri"].getStr] = textDocument["text"].getStr
    of "textDocument/didChange":
      let textDocument = valueOrEmpty(params, "textDocument")
      let uriText =
        if textDocument.hasKey("uri"):
          textDocument["uri"].getStr
        else:
          ""
      if uriText.len > 0 and params.hasKey("contentChanges") and
          params["contentChanges"].kind == JArray:
        for change in params["contentChanges"].items:
          if change.kind == JObject and change.hasKey("text"):
            documents[uriText] = change["text"].getStr
    of "textDocument/didClose":
      let textDocument = valueOrEmpty(params, "textDocument")
      if textDocument.hasKey("uri"):
        documents.del textDocument["uri"].getStr
    of "$/cancelRequest":
      discard
    of "textDocument/codeAction":
      if hasId:
        sendResponse(id, codeActions(params, documents, options))
    else:
      if hasId:
        sendError(id, -32601, "method not supported: " & methodName)
