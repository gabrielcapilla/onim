import std/[os, sets, strutils, tables, unittest]

import onim/index/surfaces
import onim/stdlib/map

proc sameCandidate(left, right: SymbolCandidate): bool =
  left.module == right.module and left.name == right.name and left.kind == right.kind and
    left.arity == right.arity and left.signature == right.signature and
    left.documentation == right.documentation and left.priority == right.priority

proc assertSameMap(expected, actual: StdlibMap) =
  check actual.surfaceIsComplete
  check actual.modules.card == expected.modules.card
  check actual.symbols.len == expected.symbols.len
  for module in expected.modules:
    check module in actual.modules
  for name, expectedCandidates in expected.symbols:
    check actual.symbols.hasKey(name)
    let actualCandidates = actual.symbols[name]
    check actualCandidates.len == expectedCandidates.len
    if actualCandidates.len == expectedCandidates.len:
      for index in 0 ..< expectedCandidates.len:
        check sameCandidate(expectedCandidates[index], actualCandidates[index])

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
  test "matches the compiler-derived JSON map":
    let root = currentSourcePath().parentDir.parentDir / "src"
    let expected = loadStdlibMap(root / "stdlib_map.json")
    let actual = loadStdlibBinary(root / "stdlib_map.bin")
    check expected.surfaceIsComplete
    assertSameMap(expected, actual)
    check actual.implicitModule("std/system")
    let surface = actual.surfaceIndex()
    check surface.valid
    check surface.lookupInModule("std/os", "walkDir").candidates.len == 1
    check surface.lookupInModule("std/tables", "Table").candidates.len == 1
    check actual.symbols["walkDir"][0].documentation.contains("Walks over")

  test "rejects malformed binary envelopes":
    let source =
      readFile(currentSourcePath().parentDir.parentDir / "src" / "stdlib_map.bin")

    var truncated = source
    truncated.setLen(truncated.len - 1)
    checkMalformed(truncated, "truncated")

    var checksum = source
    checksum[24] = char(ord(checksum[24]) xor 1)
    checkMalformed(checksum, "checksum")

    checkMalformed(source & "\0", "trailing")
