import std/os

import ./map

proc findStdlibMap*(): string =
  let configured = getEnv("ONIM_STDLIB_MAP")
  if configured.len > 0 and fileExists(configured):
    return configured
  let candidates = [
    getAppDir() / "stdlib_map.json",
    getCurrentDir() / "stdlib_map.json",
    getAppDir() / ".." / "share" / "onim" / "stdlib_map.json",
  ]
  for candidate in candidates:
    if fileExists(candidate):
      return candidate
  ""

var cachedMap: StdlibMap
var cachedMapPath = ""
var hasCachedMap = false

proc stdlibMap*(): StdlibMap =
  let configured = getEnv("ONIM_STDLIB_MAP")
  let cacheKey = if configured.len > 0: configured else: "<bundled>"
  if not hasCachedMap or cacheKey != cachedMapPath:
    cachedMap =
      if configured.len > 0:
        loadStdlibMap(configured)
      else:
        loadStdlibMap("")
    cachedMapPath = cacheKey
    hasCachedMap = true
  cachedMap
