import std/[os, sequtils, strutils, unittest]

import onim/features/completion
import onim/index/cache
import onim/index/source_index
import onim/session/ids as onimIds
import onim/session/workspace
import onim/stdlib/map

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

  test "completes canonical stdlib module members":
    let root = getTempDir() / ("onim-module-completion-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-module-completion-cache-" & $getCurrentProcessId())
    if dirExists(root):
      removeDir(root)
    if dirExists(cacheRoot):
      removeDir(cacheRoot)
    createDir(root)
    let path = root / "main.nim"
    let direct = """import std/os as filesystem
proc main() =
  filesystem.walkD
"""
    writeFile(path, direct)
    let previous = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previous.len > 0:
        putEnv("ONIM_CACHE_DIR", previous)
      else:
        delEnv("ONIM_CACHE_DIR")
      removeFile(path)
      removeDir(root)
      if dirExists(cacheRoot):
        removeDir(cacheRoot)

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let stdlib = loadStdlibMap("")
    let directId = workspace.fileIdForPath(path)
    let directSnapshot = workspace.snapshotForFile(directId)
    let directOffset = direct.find("filesystem.walkD") + "filesystem.".len + "walkD".len
    let directResult = completeAt(workspace, directSnapshot, directOffset, stdlib)
    check directResult.state == completionAvailable
    check directResult.replaceStart == direct.find("walkD")
    check directResult.replaceEnd == directOffset
    check directResult.items.anyIt(it.label == "walkDir")
    check directResult.items.anyIt(it.label == "walkDirRec")
    check completeAt(workspace, directSnapshot, directOffset, emptyStdlibMap()).state ==
      completionUnsupported

    let legacy = """import os as filesystem
proc main() =
  filesystem.
"""
    discard workspace.changeDocument("file://" & path, path, legacy, 2)
    let legacySnapshot = workspace.snapshotForFile(directId)
    let legacyOffset = legacy.find("filesystem.") + "filesystem.".len
    let legacyResult = completeAt(workspace, legacySnapshot, legacyOffset, stdlib)
    check legacyResult.state == completionUnsupported

  test "completes project members, refreshes overlays, and respects precedence":
    let root = getTempDir() / ("onim-project-completion-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-project-completion-cache-" & $getCurrentProcessId())
    if dirExists(root):
      removeDir(root)
    if dirExists(cacheRoot):
      removeDir(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let shadowPath = root / "stdlib_shadow.nim"
    let provider = """proc answer*() = discard
proc another*() = discard
proc private() = discard
"""
    let consumer = """import provider as p
proc main() =
  p.an
"""
    writeFile(providerPath, provider)
    writeFile(consumerPath, consumer)
    writeFile(root / "os.nim", "proc localOnly*() = discard\n")
    writeFile(shadowPath, "import os\nproc main() =\n  os.loc\n")
    let previous = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previous.len > 0:
        putEnv("ONIM_CACHE_DIR", previous)
      else:
        delEnv("ONIM_CACHE_DIR")
      for path in [providerPath, consumerPath, shadowPath, root / "os.nim"]:
        if fileExists(path):
          removeFile(path)
      removeDir(root)
      if dirExists(cacheRoot):
        removeDir(cacheRoot)

    let stdlib = loadStdlibMap("")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let consumerId = workspace.fileIdForPath(consumerPath)
    let consumerSnapshot = workspace.snapshotForFile(consumerId)
    let memberOffset = consumer.find("p.an") + "p.an".len
    let projectResult = completeAt(workspace, consumerSnapshot, memberOffset, stdlib)
    check projectResult.state == completionAvailable
    check projectResult.items.anyIt(it.label == "answer")
    check projectResult.items.anyIt(it.label == "another")
    check not projectResult.items.anyIt(it.label == "private")
    check projectResult.items.anyIt(it.kind == completionFunction)

    let shadowId = workspace.fileIdForPath(shadowPath)
    let shadowSnapshot = workspace.snapshotForFile(shadowId)
    let shadowOffset = shadowSnapshot.text.find("os.loc") + "os.loc".len
    let shadowResult = completeAt(workspace, shadowSnapshot, shadowOffset, stdlib)
    check shadowResult.state == completionAvailable
    check shadowResult.items.mapIt(it.label) == @["localOnly"]

    let overlay = """proc answer*() = discard
proc anew*() = discard
"""
    discard workspace.openDocument("file://" & providerPath, providerPath, overlay, 2)
    let refreshedSnapshot = workspace.snapshotForFile(consumerId)
    let refreshedResult = completeAt(workspace, refreshedSnapshot, memberOffset, stdlib)
    check refreshedResult.state == completionAvailable
    check refreshedResult.items.anyIt(it.label == "anew")
    check not refreshedResult.items.anyIt(it.label == "another")

    let shadowed = """import provider as p
proc main(p: int) =
  p.an
"""
    discard
      workspace.changeDocument("file://" & consumerPath, consumerPath, shadowed, 3)
    let shadowedSnapshot = workspace.snapshotForFile(consumerId)
    let shadowedOffset = shadowed.find("p.an") + "p.an".len
    check completeAt(workspace, shadowedSnapshot, shadowedOffset, stdlib).state ==
      completionUnsupported

    let implicit = """import provider as result
proc use(): int =
  result.an
"""
    discard
      workspace.changeDocument("file://" & consumerPath, consumerPath, implicit, 4)
    let implicitSnapshot = workspace.snapshotForFile(consumerId)
    let implicitOffset = implicit.find("result.an") + "result.an".len
    check completeAt(workspace, implicitSnapshot, implicitOffset, stdlib).state ==
      completionUnsupported

    let conditional = """when defined(posix):
  import provider as p
proc use() =
  p.an
"""
    discard
      workspace.changeDocument("file://" & consumerPath, consumerPath, conditional, 5)
    let conditionalSnapshot = workspace.snapshotForFile(consumerId)
    let conditionalOffset = conditional.find("p.an") + "p.an".len
    check completeAt(workspace, conditionalSnapshot, conditionalOffset, stdlib).state ==
      completionUnsupported

    let excluded = """import provider except answer
proc use() =
  provider.an
"""
    discard
      workspace.changeDocument("file://" & consumerPath, consumerPath, excluded, 6)
    let excludedSnapshot = workspace.snapshotForFile(consumerId)
    let excludedOffset = excluded.find("provider.an") + "provider.an".len
    check completeAt(workspace, excludedSnapshot, excludedOffset, stdlib).state ==
      completionUnsupported

    let duplicate = """import provider as p
import std/os as p
proc use() =
  p.an
"""
    discard
      workspace.changeDocument("file://" & consumerPath, consumerPath, duplicate, 7)
    let duplicateSnapshot = workspace.snapshotForFile(consumerId)
    let duplicateOffset = duplicate.find("p.an") + "p.an".len
    check completeAt(workspace, duplicateSnapshot, duplicateOffset, stdlib).state ==
      completionUnsupported
