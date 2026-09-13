import std/[json, streams, strutils]

proc frameMessage*(body: string): string =
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc frameMessage*(message: JsonNode): string =
  frameMessage($message)

proc sendMessage*(output: Stream, message: JsonNode) =
  output.write frameMessage(message)
  output.flush

proc sendMessage*(message: JsonNode) =
  stdout.write frameMessage(message)
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

proc readMessageText*(input: Stream): string =
  var contentLength = -1
  var line = ""
  while input.readLine(line):
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
    result = input.readStr(contentLength)
  except CatchableError:
    result = ""

proc readMessageText*(): string {.gcsafe.} =
  readMessageText(newFileStream(stdin))
