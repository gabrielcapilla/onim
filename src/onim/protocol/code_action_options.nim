import std/json

proc supportsOrganize*(params: JsonNode): bool =
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
