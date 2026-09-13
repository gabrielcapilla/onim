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
proc scale*(value: int) = discard
proc makeValues*(): seq[int] = nil
proc total*(values: seq[int]) = discard
proc private() = discard
"""
    let consumer = """import provider as p
from provider import scale, total, answer
from provider import answer as execute
ans
proc main() =
  p.an
proc useImported() =
  ans
  exe
proc use(value: int) =
  value.sc
proc useValues() =
  let values = p.makeValues()
  values.to
proc shadow() =
  let answer = 1
  ans
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

    let moduleAnswerStart = consumer.find("\nans\n") + 1
    let moduleAnswerOffset = moduleAnswerStart + "ans".len
    let moduleAnswerResult =
      completeAt(workspace, consumerSnapshot, moduleAnswerOffset, emptyStdlibMap())
    check moduleAnswerResult.state == completionAvailable
    check moduleAnswerResult.items.anyIt(it.label == "answer")
    check moduleAnswerResult.replaceStart == moduleAnswerStart
    check moduleAnswerResult.replaceEnd == moduleAnswerOffset

    let answerOffset = consumer.find("  ans\n") + 5
    let answerResult =
      completeAt(workspace, consumerSnapshot, answerOffset, emptyStdlibMap())
    check answerResult.state == completionAvailable
    check answerResult.items.anyIt(it.label == "answer")
    check not answerResult.items.anyIt(it.label == "private")

    let executeOffset = consumer.find("  exe\n") + 5
    let executeResult = completeAt(workspace, consumerSnapshot, executeOffset, stdlib)
    check executeResult.state == completionAvailable
    check executeResult.items.mapIt(it.label) == @["execute"]

    let localShadowOffset = consumer.rfind("  ans\n") + 5
    let localShadowResult =
      completeAt(workspace, consumerSnapshot, localShadowOffset, stdlib)
    check localShadowResult.state == completionAvailable
    check localShadowResult.items.countIt(it.label == "answer") == 1
    check localShadowResult.items.anyIt(
      it.label == "answer" and it.kind == completionVariable
    )

    let ufcsOffset = consumer.find("value.sc") + "value.sc".len
    let ufcsResult = completeAt(workspace, consumerSnapshot, ufcsOffset, stdlib)
    check ufcsResult.state == completionAvailable
    check ufcsResult.items.mapIt(it.label) == @["scale"]
    check ufcsResult.items[0].kind == completionMethod

    let sequenceOffset = consumer.find("values.to") + "values.to".len
    let sequenceResult = completeAt(workspace, consumerSnapshot, sequenceOffset, stdlib)
    check sequenceResult.state == completionAvailable
    check sequenceResult.items.mapIt(it.label) == @["total"]
    check sequenceResult.items[0].kind == completionMethod

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
    let conditionalResult =
      completeAt(workspace, conditionalSnapshot, conditionalOffset, stdlib)
    check conditionalResult.state == completionAvailable
    check conditionalResult.items.anyIt(it.label == "answer")

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

  test "completes exported fields from indexed project types":
    let root = getTempDir() / ("onim-project-type-completion-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-project-type-completion-cache-" & $getCurrentProcessId())
    if dirExists(root):
      removeDir(root)
    if dirExists(cacheRoot):
      removeDir(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let fromPath = root / "from_consumer.nim"
    let ordinaryPath = root / "ordinary_consumer.nim"
    let provider = """type
  Person* = object
    old*: string
    private: int
    age*: int
proc makePerson*(): ref Person = discard
"""
    let consumer = """import provider as model
proc show(value: ref model.Person; raw: ptr model.Person) =
  value.
  raw.ag
proc make() =
  let made = model.Person(old: "Ada")
  made.ol
  let returned = model.makePerson()
  returned.ol
"""
    let fromConsumer = """from provider import Person
from provider import makePerson
proc show(value: Person) =
  value.ol
  let made = makePerson()
  made.ol
"""
    let ordinaryConsumer = """import provider
proc show(value: Person) =
  value.ol
"""
    writeFile(providerPath, provider)
    writeFile(consumerPath, consumer)
    writeFile(fromPath, fromConsumer)
    writeFile(ordinaryPath, ordinaryConsumer)
    let previous = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previous.len > 0:
        putEnv("ONIM_CACHE_DIR", previous)
      else:
        delEnv("ONIM_CACHE_DIR")
      for path in [providerPath, consumerPath, fromPath, ordinaryPath]:
        if fileExists(path):
          removeFile(path)
      if dirExists(root):
        removeDir(root)
      if dirExists(cacheRoot):
        removeDir(cacheRoot)

    let stdlib = loadStdlibMap("")
    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let consumerId = workspace.fileIdForPath(consumerPath)
    let consumerSnapshot = workspace.snapshotForFile(consumerId)
    let valueOffset = consumer.find("value.") + "value.".len
    let valueResult = completeAt(workspace, consumerSnapshot, valueOffset, stdlib)
    check valueResult.state == completionAvailable
    check valueResult.items.mapIt(it.label) == @["age", "old", "show"]
    check not valueResult.items.anyIt(it.label == "private")

    let rawOffset = consumer.find("raw.ag") + "raw.ag".len
    let rawResult = completeAt(workspace, consumerSnapshot, rawOffset, stdlib)
    check rawResult.state == completionAvailable
    check rawResult.items.mapIt(it.label) == @["age"]

    let madeOffset = consumer.find("made.ol") + "made.ol".len
    let madeResult = completeAt(workspace, consumerSnapshot, madeOffset, stdlib)
    check madeResult.state == completionAvailable
    check madeResult.items.mapIt(it.label) == @["old"]

    let returnedOffset = consumer.find("returned.ol") + "returned.ol".len
    let returnedResult = completeAt(workspace, consumerSnapshot, returnedOffset, stdlib)
    check returnedResult.state == completionAvailable
    check returnedResult.items.mapIt(it.label) == @["old"]

    let fromId = workspace.fileIdForPath(fromPath)
    let fromSnapshot = workspace.snapshotForFile(fromId)
    let fromOffset = fromConsumer.find("value.ol") + "value.ol".len
    let fromResult = completeAt(workspace, fromSnapshot, fromOffset, stdlib)
    check fromResult.state == completionAvailable
    check fromResult.items.mapIt(it.label) == @["old"]

    let fromFactoryOffset = fromConsumer.find("made.ol") + "made.ol".len
    let fromFactoryResult =
      completeAt(workspace, fromSnapshot, fromFactoryOffset, stdlib)
    check fromFactoryResult.state == completionAvailable
    check fromFactoryResult.items.mapIt(it.label) == @["old"]

    let ordinaryId = workspace.fileIdForPath(ordinaryPath)
    let ordinarySnapshot = workspace.snapshotForFile(ordinaryId)
    let ordinaryOffset = ordinaryConsumer.find("value.ol") + "value.ol".len
    let ordinaryResult = completeAt(workspace, ordinarySnapshot, ordinaryOffset, stdlib)
    check ordinaryResult.state == completionAvailable
    check ordinaryResult.items.mapIt(it.label) == @["old"]

    let reloaded = initWorkspace(root)
    reloaded.indexWorkspace()
    check reloaded.graphComplete
    let reloadedId = reloaded.fileIdForPath(consumerPath)
    let reloadedSnapshot = reloaded.snapshotForFile(reloadedId)
    let reloadedResult = completeAt(reloaded, reloadedSnapshot, valueOffset, stdlib)
    check reloadedResult.state == completionAvailable
    check reloadedResult.items.mapIt(it.label) == @["age", "old", "show"]
    let reloadedReturnedOffset = consumer.find("returned.ol") + "returned.ol".len
    let reloadedReturned =
      completeAt(reloaded, reloadedSnapshot, reloadedReturnedOffset, stdlib)
    check reloadedReturned.state == completionAvailable
    check reloadedReturned.items.mapIt(it.label) == @["old"]

    let overlay = """type
  Person* = object
    new*: string
    private: int
    age*: int
proc makePerson*(): Person = discard
"""
    discard workspace.openDocument("file://" & providerPath, providerPath, overlay, 2)
    let refreshed = workspace.snapshotForFile(consumerId)
    let refreshedResult = completeAt(workspace, refreshed, valueOffset, stdlib)
    check refreshedResult.state == completionAvailable
    check refreshedResult.items.mapIt(it.label) == @["age", "new", "show"]
    check not refreshedResult.items.anyIt(it.label == "old")
    let returnedDotOffset = consumer.find("returned.") + "returned.".len
    let refreshedReturned = completeAt(workspace, refreshed, returnedDotOffset, stdlib)
    check refreshedReturned.state == completionAvailable
    check refreshedReturned.items.mapIt(it.label) == @["age", "new"]
