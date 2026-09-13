import std/[os, strutils, tables, unittest]

import onim/index/surfaces
import onim/stdlib/cache_paths
import onim/index/surface_resolution
import onim/stdlib/map
import onim/stdlib/toolchain

proc checkMalformed(content: string, suffix: string) =
  let path = getTempDir() / ("onim-invalid-stdlib-" & suffix & ".bin")
  try:
    writeFile(path, content)
    let fallback = loadStdlibBinary(path)
    check fallback.surfaceIndex().valid
    check not fallback.surfaceIsComplete
  finally:
    if fileExists(path):
      removeFile(path)

suite "packed stdlib map":
  test "loads the active toolchain cache":
    let toolchain = resolveNimToolchain(getCurrentDir())
    check toolchain.state == toolchainReady
    if toolchain.state == toolchainReady:
      check validStdlibCache(toolchain)
      let actual = loadStdlibBinary(stdlibBinaryPath(toolchain))
      check actual.surfaceIsComplete
      check actual.implicitModule("std/system")
      let surface = actual.surfaceIndex()
      check surface.valid
      check surface.lookupInModule("std/os", "walkDir").candidates.len == 1
      check surface.lookupInModule("std/tables", "Table").candidates.len == 1
      check actual.symbols["walkDir"][0].documentation.contains("Walks over")
      check actual.symbols.hasKey("fmt")
      check actual.documentationForModule("std/strformat").len > 0
      var formattedDocumentation = false
      for candidate in actual.symbols["fmt"]:
        if candidate.documentation.contains("dummy untyped"):
          formattedDocumentation = true
          check not candidate.documentation.contains("<tt")
      check formattedDocumentation

  test "rejects malformed binary envelopes":
    let toolchain = resolveNimToolchain(getCurrentDir())
    check toolchain.state == toolchainReady
    if toolchain.state == toolchainReady:
      let path = stdlibBinaryPath(toolchain)
      check fileExists(path)
      if fileExists(path):
        let source = readFile(path)

        var truncated = source
        truncated.setLen(truncated.len - 1)
        checkMalformed(truncated, "truncated")

        var checksum = source
        checksum[24] = char(ord(checksum[24]) xor 1)
        checkMalformed(checksum, "checksum")

        checkMalformed(source & "\0", "trailing")
