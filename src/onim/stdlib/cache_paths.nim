import std/[os, strutils, times]

import ../index/cache
import ./toolchain

const stdlibCacheSchema* = "v1"

proc stdlibCacheDirectory*(toolchain: NimToolchain): string =
  if toolchain.state != toolchainReady:
    return ""
  onimCacheRoot() / "stdlib" / stdlibCacheSchema / toolchain.key

proc stdlibBinaryPath*(toolchain: NimToolchain): string =
  let directory = stdlibCacheDirectory(toolchain)
  if directory.len > 0:
    result = directory / "stdlib_map.bin"

proc stdlibManifestPath*(toolchain: NimToolchain): string =
  let directory = stdlibCacheDirectory(toolchain)
  if directory.len > 0:
    result = directory / "manifest"

proc stdlibManifest*(toolchain: NimToolchain): string =
  "ONIMSTDLIB1\n" & stdlibCacheSchema & "\n" & toolchain.key & "\n" & toolchain.nimExe &
    "\n" & toolchain.libPath & "\n" & toolchain.version & "\n" & hostOS & "\n" & hostCPU &
    "\n"

proc validStdlibCache*(toolchain: NimToolchain): bool =
  let binary = stdlibBinaryPath(toolchain)
  let manifest = stdlibManifestPath(toolchain)
  if binary.len == 0 or manifest.len == 0 or not fileExists(binary) or
      not fileExists(manifest):
    return false
  try:
    readFile(manifest) == stdlibManifest(toolchain)
  except CatchableError:
    false

proc stdlibTemporaryPath*(path, suffix: string): string =
  path & ".tmp." & $getCurrentProcessId() & "." & $epochTime() & suffix
