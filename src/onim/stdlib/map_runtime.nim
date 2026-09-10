import std/[os, strutils]

import ./cache_paths
import ./cache_worker
import ./map
import ./toolchain

type StdlibRuntimeState* = enum
  stdlibRuntimeUnavailable
  stdlibRuntimeGenerating
  stdlibRuntimeReady
  stdlibRuntimeFailed

var cachedMap: StdlibMap
var cachedRoot = ""
var cachedOverride = ""
var cachedState = stdlibRuntimeUnavailable

proc configuredMapPath(): string =
  getEnv("ONIM_STDLIB_MAP")

proc loadConfiguredMap(path: string): StdlibMap =
  if path.toLowerAscii.endsWith(".json"):
    loadStdlibMap(path)
  else:
    loadStdlibBinary(path)

proc cacheMap(
    root: string, overridePath: string, value: StdlibMap, state: StdlibRuntimeState
) =
  cachedRoot = root
  cachedOverride = overridePath
  cachedMap = value
  cachedState = state

proc findStdlibMap*(workingDir: string = ""): string =
  let configured = configuredMapPath()
  if configured.len > 0:
    return configured
  let toolchain = resolveNimToolchain(
    if workingDir.len > 0:
      workingDir
    else:
      getCurrentDir()
  )
  if toolchain.state == toolchainReady:
    return stdlibBinaryPath(toolchain)

proc startStdlibMap*(root: string, map: var StdlibMap): StdlibRuntimeState =
  let workingDir =
    if root.len > 0:
      root
    else:
      getCurrentDir()
  let configured = configuredMapPath()
  if configured.len > 0:
    map = loadConfiguredMap(configured)
    let state = if map.surfaceIsComplete: stdlibRuntimeReady else: stdlibRuntimeFailed
    cacheMap(workingDir, configured, map, state)
    return state
  if cachedRoot == workingDir and cachedOverride.len == 0:
    map = cachedMap
    if cachedState != stdlibRuntimeUnavailable:
      return cachedState
  let toolchain = resolveNimToolchain(workingDir)
  if toolchain.state == toolchainReady and validStdlibCache(toolchain):
    let loaded = loadStdlibBinary(stdlibBinaryPath(toolchain))
    if loaded.surfaceIsComplete:
      map = loaded
      cacheMap(workingDir, "", loaded, stdlibRuntimeReady)
      return stdlibRuntimeReady
  if toolchain.state != toolchainReady or
      not startStdlibGeneration(workingDir, toolchain):
    map = emptyStdlibMap()
    cacheMap(workingDir, "", map, stdlibRuntimeFailed)
    return stdlibRuntimeFailed
  map = emptyStdlibMap()
  cacheMap(workingDir, "", map, stdlibRuntimeGenerating)
  stdlibRuntimeGenerating

proc pollStdlibMap*(map: var StdlibMap): StdlibRuntimeState =
  if cachedState != stdlibRuntimeGenerating:
    map = cachedMap
    return cachedState
  var path = ""
  let generation = pollStdlibGeneration(path)
  case generation
  of stdlibGenerationRunning:
    return stdlibRuntimeGenerating
  of stdlibGenerationReady:
    let loaded = loadStdlibBinary(path)
    if loaded.surfaceIsComplete:
      cachedMap = loaded
      map = loaded
      cachedState = stdlibRuntimeReady
      return cachedState
    cachedState = stdlibRuntimeFailed
  of stdlibGenerationFailed, stdlibGenerationIdle:
    cachedState = stdlibRuntimeFailed
  map = cachedMap
  cachedState

proc stopStdlibMapGeneration*() =
  if cachedState == stdlibRuntimeGenerating:
    stopStdlibGeneration()
    cachedState = stdlibRuntimeFailed

proc stdlibMap*(workingDir: string = "", waitForGeneration: bool = true): StdlibMap =
  let root =
    if workingDir.len > 0:
      workingDir
    else:
      getCurrentDir()
  let configured = configuredMapPath()
  if cachedRoot == root and cachedOverride == configured and cachedMap != nil and
      cachedState == stdlibRuntimeReady:
    return cachedMap
  var value: StdlibMap
  let state = startStdlibMap(root, value)
  if state == stdlibRuntimeGenerating and waitForGeneration:
    var path = ""
    if waitStdlibGeneration(path) == stdlibGenerationReady:
      value = loadStdlibBinary(path)
      if value.surfaceIsComplete:
        cacheMap(root, "", value, stdlibRuntimeReady)
      else:
        cacheMap(root, "", value, stdlibRuntimeFailed)
    else:
      cacheMap(root, "", value, stdlibRuntimeFailed)
  value
