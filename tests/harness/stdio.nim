import std/[json, streams]

import onim/protocol/transport

proc sendMessage*(input: Stream, message: JsonNode) =
  input.write(frameMessage(message))
  input.flush

proc sendRaw*(input: Stream, body: string) =
  input.write(frameMessage(body))
  input.flush

proc readMessage*(output: Stream): JsonNode =
  let body = readMessageText(output)
  if body.len == 0:
    return
  parseJson(body)

proc readResponse*(output: Stream, id: int): JsonNode =
  while true:
    let message = readMessage(output)
    if message == nil:
      return
    if message.hasKey("id") and message["id"].kind == JInt and message["id"].getInt == id:
      return message

proc readDiagnostics*(output: Stream, uri: string): JsonNode =
  while true:
    let message = readMessage(output)
    if message == nil:
      return
    if message.hasKey("method") and
        message["method"].getStr == "textDocument/publishDiagnostics" and
        message["params"]["uri"].getStr == uri:
      return message

proc readUnusedDeclarationDiagnostics*(output: Stream, uri: string): JsonNode =
  for _ in 0 ..< 4:
    let message = readDiagnostics(output, uri)
    if message == nil:
      return
    result = message
    for diagnostic in message["params"]["diagnostics"]:
      if diagnostic.hasKey("code") and diagnostic["code"].kind == JString and
          diagnostic["code"].getStr == "XDeclaredButNotUsed":
        return
