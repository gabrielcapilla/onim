import std/[json, streams, strutils]

proc sendMessage*(message: JsonNode) =
  let body = $message
  stdout.write "Content-Length: " & $body.len & "\r\n\r\n"
  stdout.write body
  stdout.flushFile()

proc sendResponse*(id, value: JsonNode) =
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["id"] = id
  message["result"] = value
  sendMessage(message)

proc sendError*(id: JsonNode, code: int, messageText: string) =
  var error = newJObject()
  error["code"] = %code
  error["message"] = %messageText
  var response = newJObject()
  response["jsonrpc"] = %"2.0"
  response["id"] = id
  response["error"] = error
  sendMessage(response)

proc readMessageText*(): string {.gcsafe.} =
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
