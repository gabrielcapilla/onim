import std/[os, sequtils, sets, strutils, unittest]

import harness/fixture
import harness/source
import onim/features/completion
import onim/features/completion_models
import onim/features/inlay
import onim/features/typo
import onim/index/cache
import onim/index/source_index
import onim/session/workspace
import onim/session/workspace_models
import onim/stdlib/map
import onim/stdlib/map_runtime
import features/completion_support

suite "native completion":
  test "uses marker fixtures for feature positions":
    let fixture = parseFixture("proc show() =\n  let localValue = 10\n  echo loc<|>\n")
    let snapshot = fixtureSnapshot(fixture)
    let result = completeAt(
      initWorkspace(), snapshot, fixture.cursors[0].byteOffset, emptyStdlibMap()
    )
    check result.state == completionAvailable
    check result.items.anyIt(it.label == "localValue")
    check result.replaceStart == fixture.cursors[0].byteOffset - 3
    check result.replaceEnd == fixture.cursors[0].byteOffset

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

  test "completes primitive type annotations":
    let source = "proc show() =\n  var n: u\n  discard n\n"
    let result = memberCompletionAt(source, "u")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) ==
      @["uint", "uint16", "uint32", "uint64", "uint8"]
    check result.items.allIt(it.kind == completionType)

  test "completes empty type and condition prefixes":
    let typeSource = "proc show() =\n  var n: \n  discard n\n"
    let typeOffset = typeSource.rfind("var n: ") + "var n: ".len
    let typeResult =
      completeAt(initWorkspace(), localSnapshot(typeSource), typeOffset, stdlibMap())
    check typeResult.state == completionAvailable
    check typeResult.items.mapIt(it.label) ==
      @[
        "bool", "char", "float", "float128", "float32", "float64", "int", "int16",
        "int32", "int64", "int8", "string", "uint", "uint16", "uint32", "uint64",
        "uint8",
      ]
    check typeResult.replaceStart == typeOffset
    check typeResult.replaceEnd == typeOffset

    let conditionSource = "when \n  discard\n"
    let conditionOffset = conditionSource.rfind("when ") + "when ".len
    let conditionResult = completeAt(
      initWorkspace(), localSnapshot(conditionSource), conditionOffset, stdlibMap()
    )
    check conditionResult.state == completionAvailable
    check conditionResult.items.mapIt(it.label).contains("isMainModule")
    check conditionResult.replaceStart == conditionOffset
    check conditionResult.replaceEnd == conditionOffset

  test "completes local names inside fmt interpolation":
    let source = """proc show() =
  let world = "World"
  stdout.writeLine fmt"hello, {wor}"
"""
    let snapshot = localSnapshot(source)
    let offset = source.rfind("{wor") + "{wor".len
    let result = completeAt(initWorkspace(), snapshot, offset, emptyStdlibMap())
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["world"]
    check result.replaceStart == source.rfind("wor")
    check result.replaceEnd == offset

  test "completes module values inside fmt interpolation":
    let source = """let world = "World"

proc show() =
  stdout.writeLine fmt"hello, {wor}"
"""
    let snapshot = localSnapshot(source)
    let offset = source.rfind("{wor") + "{wor".len
    let result = completeAt(initWorkspace(), snapshot, offset, emptyStdlibMap())
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["world"]
    check result.replaceStart == source.rfind("wor")
    check result.replaceEnd == offset

  test "completes the built-in main-module condition":
    let source = "when isMain:\n  discard\n"
    let result = completeAt(
      initWorkspace(),
      localSnapshot(source),
      source.rfind("isMain") + "isMain".len,
      stdlibMap(),
    )
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["isMainModule"]
    check result.items[0].kind == completionConstant

    let keywordResult = completeAt(
      initWorkspace(),
      localSnapshot("when is\n"),
      "when is\n".rfind("is") + "is".len,
      stdlibMap(),
    )
    check keywordResult.state == completionAvailable
    check keywordResult.items.mapIt(it.label) == @["isMainModule"]

  test "keeps literal inlay hints in incomplete declarations and conditions":
    let incomplete = localSnapshot("let value = 1\nproc main() =\n")
    check inferredInlayHints(initWorkspace(), incomplete, 0, incomplete.text.len).len ==
      1

    let conditional = localSnapshot("let value = 1\nwhen isMainModule:\n")
    check inferredInlayHints(initWorkspace(), conditional, 0, conditional.text.len).len ==
      1

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

    let topLevel = "proc main() =\n  discard\n\nma\n"
    let topLevelResult = completionAt(topLevel, "ma")
    check topLevelResult.state == completionAvailable
    check topLevelResult.items.mapIt(it.label).contains("main")
    check topLevelResult.items.anyIt(
      it.label == "main" and it.kind == completionFunction
    )

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

  test "dispatches ordinary locals and rejects malformed members":
    let source = """proc show(value: int) =
  let localValue = value
  echo loc
"""
    let snapshot = localSnapshot(source)
    let workspace = initWorkspace()
    let ordinary =
      completeAt(workspace, snapshot, source.rfind("loc") + 3, emptyStdlibMap())
    check ordinary.state == completionAvailable
    check ordinary.items.mapIt(it.label) == @["localValue"]

    let chained = """import std/os as filesystem
proc show() =
  filesystem.os.walkD
"""
    let chainedSnapshot = localSnapshot(chained)
    let chainedOffset = chained.rfind("walkD") + "walkD".len
    check completeAt(workspace, chainedSnapshot, chainedOffset, emptyStdlibMap()).state ==
      completionUnsupported

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

  test "matches fresh and incrementally updated type indexes":
    let oldSource = """type
  Alpha = object
    alpha: int
  Bravo = object
    bravo: int

proc show() =
  let value = Alpha()
  value.
"""
    let newSource = oldSource.replace("Alpha()", "Bravo()")
    let oldIndex = indexSource(oldSource)
    let updated = tryIndexSourceIncremental(oldSource, oldIndex, newSource)
    check updated != nil
    var snapshot = localSnapshot(newSource)
    snapshot.index = updated
    let result = completeAt(
      initWorkspace(),
      snapshot,
      newSource.find("value.") + "value.".len,
      emptyStdlibMap(),
    )
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["bravo"]
