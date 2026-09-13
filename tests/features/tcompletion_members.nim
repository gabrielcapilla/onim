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
  test "completes fields of named tuple aliases":
    let source = """type Point = tuple[x: int, y: string]
proc show(point: Point) =
  discard point.
"""
    let result = memberCompletionAt(source, "point.")
    check result.state == completionAvailable
    check result.items.anyIt(it.label == "x" and it.kind == completionField)
    check result.items.anyIt(it.label == "y" and it.kind == completionField)

  test "completes fields of inferred named tuple literals":
    let source = """proc show() =
  let point = (x: 1, y: "ok")
  discard point.
  let unnamed = (1, "ok")
  discard unnamed.
"""
    let result = memberCompletionAt(source, "point.")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["x", "y"]
    check memberCompletionAt(source, "unnamed.").state == completionUnsupported

  test "completes fields of named tuple elements in sequences":
    let source = """proc show() =
  let people = @[(name: "Ada", age: 1), (name: "Bob", age: 2)]
  discard people[0].na
"""
    let result = memberCompletionAt(source, "people[0].na")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["name"]
    let mixed = """proc show() =
  let people = @[(name: "Ada"), (age: 1)]
  discard people[0].na
"""
    check memberCompletionAt(mixed, "people[0].na").state == completionUnsupported

  test "reconstructs object type facts from the cache":
    let root = getTempDir() / ("onim-object-completion-cache-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-object-completion-cache-data-" & $getCurrentProcessId())
    if dirExists(root):
      removeDir(root)
    if dirExists(cacheRoot):
      removeDir(cacheRoot)
    createDir(root)
    let path = root / "main.nim"
    let source = """type
  Person = object
    name: string

type Point = tuple[x: int, y: string]

proc show(person: Person) =
  person.na

proc locate(point: Point) =
  point.la
"""
    let previous = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previous.len > 0:
        putEnv("ONIM_CACHE_DIR", previous)
      else:
        delEnv("ONIM_CACHE_DIR")
      if dirExists(root):
        removeDir(root)
      if dirExists(cacheRoot):
        removeDir(cacheRoot)
    let original = indexSource(source)
    check saveCachedSourceIndex(root, path, source, original)
    let cached = loadCachedSourceIndex(root, path, source)
    check cached != nil
    let workspace = initWorkspace()
    let offset = source.find("person.na") + "person.na".len
    let fresh = completeAt(
      workspace,
      WorkspaceSnapshot(valid: true, path: path, text: source, index: original),
      offset,
      emptyStdlibMap(),
    )
    let restored = completeAt(
      workspace,
      WorkspaceSnapshot(valid: true, path: path, text: source, index: cached),
      offset,
      emptyStdlibMap(),
    )
    check restored.state == fresh.state
    check restored.items == fresh.items
    let tupleOffset = source.find("point.la") + "point.la".len
    let freshTuple = completeAt(
      workspace,
      WorkspaceSnapshot(valid: true, path: path, text: source, index: original),
      tupleOffset,
      emptyStdlibMap(),
    )
    let restoredTuple = completeAt(
      workspace,
      WorkspaceSnapshot(valid: true, path: path, text: source, index: cached),
      tupleOffset,
      emptyStdlibMap(),
    )
    check restoredTuple.state == freshTuple.state
    check restoredTuple.items == freshTuple.items

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
    let stdlib = loadStdlibMap("")
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
    check legacyResult.state == completionAvailable
    check legacyResult.replaceStart == legacy.find("filesystem.") + "filesystem.".len
    check legacyResult.replaceEnd == legacyOffset
    check legacyResult.items.anyIt(it.label == "walkDir")
    check legacyResult.items.anyIt(it.label == "walkDirRec")

  test "completes unqualified stdlib and from-import names":
    let source = """import std/os
from std/os import walkDir as visit
proc main() =
  walkD
  visi
"""
    let snapshot = localSnapshot(source)
    let workspace = initWorkspace()
    let stdlib = loadStdlibMap("")

    let walkOffset = source.rfind("walkD") + "walkD".len
    let walkResult = completeAt(workspace, snapshot, walkOffset, stdlib)
    check walkResult.state == completionAvailable
    check walkResult.items.anyIt(it.label == "walkDir")
    var walkDirCount = 0
    for item in walkResult.items:
      if item.label == "walkDir":
        inc walkDirCount
      check item.label != "walkDirs"
      check not item.autoImportModule.startsWith("private/")
    check walkDirCount == 1
    check walkResult.replaceStart == source.rfind("walkD")
    check walkResult.replaceEnd == walkOffset

    let autoSource = "proc main() =\n  walkD\n"
    let autoOffset = autoSource.rfind("walkD") + "walkD".len
    let autoResult =
      completeAt(workspace, localSnapshot(autoSource), autoOffset, stdlib)
    var autoWalkDirCount = 0
    for item in autoResult.items:
      if item.label == "walkDir":
        inc autoWalkDirCount
        check item.autoImportModule == "std/os"
      check item.label != "walkDirs"
      check not item.autoImportModule.startsWith("private/")
    check autoWalkDirCount == 1

    let visitOffset = source.rfind("visi") + "visi".len
    let visitResult = completeAt(workspace, snapshot, visitOffset, stdlib)
    check visitResult.state == completionAvailable
    check visitResult.items.anyIt(it.label == "visit")
    check not visitResult.items.anyIt(it.label == "walkDir")

    let moduleSource = """import std/os
walkD
"""
    let moduleSnapshot = localSnapshot(moduleSource)
    let moduleOffset = moduleSource.rfind("walkD") + "walkD".len
    let moduleResult = completeAt(workspace, moduleSnapshot, moduleOffset, stdlib)
    check moduleResult.state == completionAvailable
    check moduleResult.items.anyIt(it.label == "walkDir")
    check moduleResult.replaceStart == moduleSource.rfind("walkD")
    check moduleResult.replaceEnd == moduleOffset

    let shadowSource = """import std/os
proc walkDir() = discard
walkD
"""
    let shadowSnapshot = localSnapshot(shadowSource)
    let shadowOffset = shadowSource.rfind("walkD") + "walkD".len
    let shadow = completeAt(workspace, shadowSnapshot, shadowOffset, stdlib)
    check shadow.items.anyIt(it.label == "walkDir" and it.autoImportModule.len == 0)

    let aliasSource = """import std/os as filesystem
walkD
"""
    let aliasSnapshot = localSnapshot(aliasSource)
    let aliasOffset = aliasSource.rfind("walkD") + "walkD".len
    let alias = completeAt(workspace, aliasSnapshot, aliasOffset, stdlib)
    check not alias.items.anyIt(it.label == "walkDir")

  test "defers project completion while the workspace catalog is pending":
    let source = "import provider\nanswer\n"
    let workspace = initWorkspace("/tmp/onim-pending-completion")
    let result = completeAt(
      workspace,
      localSnapshot(source, "/tmp/onim-pending-completion/main.nim"),
      source.find("answer") + "answer".len,
      emptyStdlibMap(),
    )
    check result.needsBootstrap
    check result.items.len == 0

  test "completes implicit File receivers from stdlib metadata":
    let source = """proc main() =
  stdout.wri
"""
    let snapshot = localSnapshot(source)
    let workspace = initWorkspace()
    let offset = source.find("stdout.wri") + "stdout.wri".len
    let result = completeAt(workspace, snapshot, offset, loadStdlibMap(""))
    check result.state == completionAvailable
    check result.items.anyIt(it.label == "write")
    check result.items.anyIt(it.label == "writeLine")
    check not result.items.anyIt(it.label == "writeFile")
    check result.replaceStart == source.find("wri")
    check result.replaceEnd == offset

    let typedSource = """proc main(output: File) =
  output.wri
"""
    let typedSnapshot = localSnapshot(typedSource)
    let typedOffset = typedSource.find("output.wri") + "output.wri".len
    let typedResult =
      completeAt(workspace, typedSnapshot, typedOffset, loadStdlibMap(""))
    check typedResult.state == completionAvailable
    check typedResult.items.anyIt(it.label == "writeLine")

    let stderrSource = """proc main() =
  stderr.wri
"""
    let stderrSnapshot = localSnapshot(stderrSource)
    let stderrOffset = stderrSource.find("stderr.wri") + "stderr.wri".len
    check completeAt(workspace, stderrSnapshot, stderrOffset, loadStdlibMap("")).state ==
      completionAvailable

  test "keeps member completion inside the main-module conditional":
    let stdlib = loadStdlibMap("")
    let workspace = initWorkspace()
    let source = "proc helper() = discard\nwhen isMainModule:\n  stdout.wri\n"
    let offset = source.rfind("stdout.wri") + "stdout.wri".len
    let result = completeAt(workspace, localSnapshot(source), offset, stdlib)
    check result.state == completionAvailable
    check result.items.anyIt(it.label == "writeLine")
    check result.replaceStart == source.rfind("wri")
    check result.replaceEnd == offset

  test "keeps receiver completion public and recovers close typos":
    let stdlib = loadStdlibMap("")
    let workspace = initWorkspace()
    let source = "proc main() =\n  stdout.\n"
    let result = completeAt(
      workspace, localSnapshot(source), source.rfind("stdout.") + "stdout.".len, stdlib
    )
    check result.state == completionAvailable
    check result.items.anyIt(it.label == "writeLine")
    check result.items.anyIt(it.label == "writeLine" and it.detail.len > 0)
    check result.items.allIt(not it.label.startsWith("c_"))
    check result.items.allIt(it.label != "`&amp;=`")
    let labels = result.items.mapIt(it.label).toHashSet
    check labels.len == result.items.len

    let typoSource = "proc main() =\n  ehco\n"
    let typoOffset = typoSource.rfind("ehco") + "ehco".len
    let typo = completeAt(workspace, localSnapshot(typoSource), typoOffset, stdlib)
    check typo.state == completionAvailable
    check typo.items.mapIt(it.label) == @["echo"]
    check typo.items[0].recovered
    check typo.items[0].filterText == "ehco"

    let memberSource = "proc main() =\n  stdout.wrteLines\n"
    let memberOffset = memberSource.rfind("wrteLines") + "wrteLines".len
    let memberTypo =
      completeAt(workspace, localSnapshot(memberSource), memberOffset, stdlib)
    check memberTypo.state == completionAvailable
    check memberTypo.items.mapIt(it.label) == @["writeLine"]
    check memberTypo.items[0].recovered

  test "separates member insertion and replacement ranges":
    let stdlib = loadStdlibMap("")
    let workspace = initWorkspace()
    let source = "proc main() =\n  stdout.writeLine\n"
    let memberStart = source.find("writeLine")
    let cursorInside = memberStart + 4
    let inside = completeAt(workspace, localSnapshot(source), cursorInside, stdlib)
    check inside.state == completionAvailable
    check inside.items.anyIt(it.label == "writeLine")
    check inside.insertStart == memberStart
    check inside.insertEnd == cursorInside
    check inside.replaceStart == memberStart
    check inside.replaceEnd == memberStart + "writeLine".len

    let cursorAtStart = memberStart
    let atStart = completeAt(workspace, localSnapshot(source), cursorAtStart, stdlib)
    check atStart.state == completionAvailable
    check atStart.insertStart == cursorAtStart
    check atStart.insertEnd == cursorAtStart
    check atStart.replaceStart == cursorAtStart
    check atStart.replaceEnd == memberStart + "writeLine".len

  test "does not recover unrelated names at declaration tokens":
    let stdlib = loadStdlibMap("")
    let workspace = initWorkspace()
    let source = "proc main() =\n  discard\n"
    let offset = source.find("main") + "main".len
    let result = completeAt(workspace, localSnapshot(source), offset, stdlib)
    check result.items.len == 0

  test "does not flag known routines inside conditional blocks":
    let stdlib = loadStdlibMap("")
    let conditional = "proc main() = discard\nwhen isMainModule:\n  main()\n"
    let moduleLevel = "proc main() = discard\nmain()\n"
    check typoMatches(initWorkspace(), localSnapshot(conditional), stdlib).len == 0
    check typoMatches(initWorkspace(), localSnapshot(moduleLevel), stdlib).len == 0

  test "completes members from a strict stdlib nominal return":
    let stdlib = loadStdlibMap("")
    let source = """import std/httpclient
proc main() =
  let client = newHttpClient()
  client.ge
"""
    let workspace = initWorkspace()
    let offset = source.find("client.ge") + "client.ge".len
    let result = completeAt(workspace, localSnapshot(source), offset, stdlib)
    check result.state == completionAvailable
    check result.items.anyIt(it.label == "get")
    check result.replaceStart == source.find("ge")
    check result.replaceEnd == offset

    let explicit = """import std/httpclient
proc main() =
  var client: HttpClient
  client.ge
"""
    let explicitResult = completeAt(
      workspace,
      localSnapshot(explicit),
      explicit.find("client.ge") + "client.ge".len,
      stdlib,
    )
    check explicitResult.state == completionAvailable
    check explicitResult.items.anyIt(it.label == "get")

    let localType = """import std/httpclient
type HttpClient = object
  localOnly: int
proc main() =
  var client: HttpClient
  client.ge
"""
    let localTypeResult = completeAt(
      workspace,
      localSnapshot(localType),
      localType.find("client.ge") + "client.ge".len,
      stdlib,
    )
    check not localTypeResult.items.anyIt(it.label == "get")

    let noImport = """proc main() =
  let client = newHttpClient()
  client.ge
"""
    let noImportResult = completeAt(
      workspace,
      localSnapshot(noImport),
      noImport.find("client.ge") + "client.ge".len,
      stdlib,
    )
    check not noImportResult.items.anyIt(it.label == "get")

    let conditional = """when defined(enableHttp):
  import std/httpclient
proc main() =
  let client = newHttpClient()
  client.ge
"""
    let conditionalResult = completeAt(
      workspace,
      localSnapshot(conditional),
      conditional.find("client.ge") + "client.ge".len,
      stdlib,
    )
    check not conditionalResult.items.anyIt(it.label == "get")

    let fromImport = """from std/httpclient import newHttpClient
proc main() =
  let client = newHttpClient()
  client.ge
"""
    let fromResult = completeAt(
      workspace,
      localSnapshot(fromImport),
      fromImport.find("client.ge") + "client.ge".len,
      stdlib,
    )
    check not fromResult.items.anyIt(it.label == "get")

    let alias = """import std/httpclient as http
proc main() =
  let client = newHttpClient()
  client.ge
"""
    let aliasResult = completeAt(
      workspace, localSnapshot(alias), alias.find("client.ge") + "client.ge".len, stdlib
    )
    check not aliasResult.items.anyIt(it.label == "get")

    let excluded = """import std/httpclient except newHttpClient
proc main() =
  let client = newHttpClient()
  client.ge
"""
    let excludedResult = completeAt(
      workspace,
      localSnapshot(excluded),
      excluded.find("client.ge") + "client.ge".len,
      stdlib,
    )
    check not excludedResult.items.anyIt(it.label == "get")

    let shadowed = """import std/httpclient
proc newHttpClient(): int = 0
proc main() =
  let client = newHttpClient()
  client.ge
"""
    let shadowedResult = completeAt(
      workspace,
      localSnapshot(shadowed),
      shadowed.find("client.ge") + "client.ge".len,
      stdlib,
    )
    check not shadowedResult.items.anyIt(it.label == "get")
