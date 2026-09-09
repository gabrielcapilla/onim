import std/json

proc parseMessage*(payload: string): JsonNode =
  try:
    parseJson(payload)
  except CatchableError:
    nil

proc isExitPayload*(payload: string): bool {.gcsafe.} =
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
