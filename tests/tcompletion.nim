import std/[os, sequtils, strutils, unittest]

import onim/features/completion
import onim/index/cache
import onim/index/source_index
import onim/session/ids as onimIds
import onim/session/workspace

proc localSnapshot(source: string, path = "main.nim"): WorkspaceSnapshot =
  WorkspaceSnapshot(
    valid: true,
    id: onimIds.SnapshotId(1),
    fileId: onimIds.FileId(1),
    path: path,
    text: source,
    contentGeneration: onimIds.ContentGeneration(1),
    index: indexSource(source),
  )

proc completionAt(source, prefix: string): CompletionResult =
  let snapshot = localSnapshot(source)
  let offset = source.rfind(prefix) + prefix.len
  snapshot.completeLocals(offset)

suite "native local completion":
  test "returns visible parameters and locals by prefix":
    let source = """proc show(value: int) =
  let localValue = value
  var mutableValue = localValue
  const constantValue = 1
  echo loc
  echo cons
"""
    let result = completionAt(source, "loc")
    check result.state == completionAvailable
    check result.items.len == 1
    check result.items[0].label == "localValue"
    check result.items[0].kind == completionVariable
    check result.replaceStart == source.rfind("loc")
    check result.replaceEnd == result.replaceStart + 3

    let constants = completionAt(source, "cons")
    check constants.state == completionAvailable
    check constants.items.len == 1
    check constants.items[0].label == "constantValue"
    check constants.items[0].kind == completionConstant

  test "orders candidates and respects Nim identifier spelling":
    let source = """proc show(value: int) =
  let local_value = value
  var localOther = local_value
  echo l
"""
    let result = completionAt(source, "l")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["localOther", "local_value"]

  test "uses the nearest declaration for block shadowing":
    let source = """proc show(value: int) =
  block:
    let value = 1
    echo val
  echo val
"""
    let inner = localSnapshot(source)
    let first = source.find("echo val") + "echo ".len
    let second = source.find("echo val", first + 1) + "echo ".len
    let innerResult = inner.completeLocals(first + 3)
    let outerResult = inner.completeLocals(second + 3)
    check innerResult.state == completionAvailable
    check innerResult.items.mapIt(it.label) == @["value"]
    check outerResult.state == completionAvailable
    check outerResult.items.mapIt(it.label) == @["value"]

  test "does not expose declarations after the cursor":
    let source = """proc show(value: int) =
  echo val
  let laterValue = 1
"""
    let result = completionAt(source, "val")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["value"]

  test "rejects ambiguous and non-local contexts":
    let collision = """proc bad(value: int) =
  let value_ = 1
  echo val
"""
    check completionAt(collision, "val").state == completionUnsupported

    let topLevel = "let value = 1\necho val\n"
    check completionAt(topLevel, "val").state == completionUnsupported

    let qualified = """proc qualified(value: int) =
  echo object.val
"""
    check completionAt(qualified, "val").state == completionUnsupported

    let stringLiteral = """proc literal(value: int) =
  echo "loc"
"""
    check completionAt(stringLiteral, "loc").state == completionUnsupported

    let generic = """proc generic[T](value: T) =
  echo val
"""
    check completionAt(generic, "val").state == completionUnsupported

    let loop = """proc looping(value: int) =
  for value in 1 .. 2:
    echo val
"""
    check completionAt(loop, "val").state == completionUnsupported

    let conditional = """when defined(posix):
  proc conditional(value: int) =
    echo val
"""
    check completionAt(conditional, "val").state == completionUnsupported

    let implicitResult = """proc implicit(): int =
  result
"""
    check completionAt(implicitResult, "result").state == completionUnsupported

    let macroSource = """macro expand(value: int) =
  echo val
"""
    check completionAt(macroSource, "val").state == completionUnsupported

  test "matches the cached source index":
    let root = getTempDir() / ("onim-completion-cache-" & $getCurrentProcessId())
    let path = root / "main.nim"
    let source = """proc show(value: int) =
  let localValue = value
  echo loc
"""
    createDir(root)
    let previous = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", root / "cache")
    let original = indexSource(source)
    check saveCachedSourceIndex(root, path, source, original)
    let cached = loadCachedSourceIndex(root, path, source)
    check cached != nil
    let originalResult = WorkspaceSnapshot(
      valid: true, path: path, text: source, index: original
    ).completeLocals(source.rfind("loc") + 3)
    let cachedResult = WorkspaceSnapshot(
      valid: true, path: path, text: source, index: cached
    ).completeLocals(source.rfind("loc") + 3)
    check cachedResult.state == originalResult.state
    check cachedResult.items == originalResult.items
    if previous.len > 0:
      putEnv("ONIM_CACHE_DIR", previous)
    else:
      delEnv("ONIM_CACHE_DIR")
    removeDir(root)
