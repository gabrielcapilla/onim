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

proc memberCompletionAt(source, prefix: string): CompletionResult =
  let snapshot = localSnapshot(source)
  let workspace = initWorkspace()
  completeAt(workspace, snapshot, source.rfind(prefix) + prefix.len, emptyStdlibMap())

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

proc show(person: Person) =
  person.na
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
proc scale*(value: int) = discard
proc makeValues*(): seq[int] = nil
proc total*(values: seq[int]) = discard
proc private() = discard
"""
    let consumer = """import provider as p
from provider import scale, total
proc main() =
  p.an
proc use(value: int) =
  value.sc
proc useValues() =
  let values = p.makeValues()
  values.to
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
    check completeAt(workspace, ordinarySnapshot, ordinaryOffset, stdlib).state ==
      completionUnsupported

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

  test "completes fields from explicit nominal object types":
    let source = """type
  Person = object
    name: string
    age: int

proc show(person: Person) =
  person.na
"""
    let result = memberCompletionAt(source, "person.na")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["name"]
    check result.items[0].kind == completionField
    check result.replaceStart == source.rfind("na")
    check result.replaceEnd == result.replaceStart + 2

  test "completes exact UFCS members and preserves field precedence":
    let primitive = """proc scaled(value: int) = discard
proc show(value: int) =
  value.sc
"""
    let primitiveResult = memberCompletionAt(primitive, "value.sc")
    check primitiveResult.state == completionAvailable
    check primitiveResult.items.mapIt(it.label) == @["scaled"]
    check primitiveResult.items[0].kind == completionMethod

    let field = """type Item = object
  size*: int

proc size(value: Item) = discard
proc show(item: Item) =
  item.si
"""
    let fieldResult = memberCompletionAt(field, "item.si")
    check fieldResult.state == completionAvailable
    check fieldResult.items.mapIt(it.label) == @["size"]
    check fieldResult.items[0].kind == completionField

    let overloads = """proc choose(value: int; amount: int) = discard
proc choose(value: int; amount: string) = discard
proc show(value: int) =
  value.ch
"""
    let overloadResult = memberCompletionAt(overloads, "value.ch")
    check overloadResult.state == completionAvailable
    check overloadResult.items.mapIt(it.label) == @["choose"]
    check overloadResult.items[0].kind == completionMethod

  test "supports ref, ptr, constructors, and lexical type shadowing":
    let source = """type
  Shared = ref object
    value: int
  Raw = object
    flag: bool
  Person = object
    name: string
  Other = object
    code: int

proc show(shared: Shared; raw: ptr Raw; person: Person) =
  shared.va
  raw.fl
  let made = Person(name: "Ada")
  made.na
  block:
    let person: Other = Other(code: 1)
    person.co
"""
    let shared = memberCompletionAt(source, "shared.va")
    check shared.state == completionAvailable
    check shared.items.mapIt(it.label) == @["value"]
    let raw = memberCompletionAt(source, "raw.fl")
    check raw.state == completionAvailable
    check raw.items.mapIt(it.label) == @["flag"]
    let made = memberCompletionAt(source, "made.na")
    check made.state == completionAvailable
    check made.items.mapIt(it.label) == @["name"]
    let shadowed = memberCompletionAt(source, "person.co")
    check shadowed.state == completionAvailable
    check shadowed.items.mapIt(it.label) == @["code"]

  test "keeps unsupported type shapes conservative and never falls through":
    let generic = """type
  Box[T] = object
    value: T

proc show(value: Box[int]) =
  value.va
"""
    let genericResult = memberCompletionAt(generic, "value.va")
    check genericResult.state == completionAvailable
    check genericResult.items.mapIt(it.label) == @["value"]
    check genericResult.items[0].kind == completionField

    let invalidGeneric = """type Plain = object
  value: int

proc show(value: Plain[int]) =
  value.va
"""
    check memberCompletionAt(invalidGeneric, "value.va").state == completionUnsupported

    let variant = """type
  Variant = object
    case kind: bool
    of true:
      first: int
    else:
      second: int

proc show(value: Variant) =
  value.fi
"""
    check memberCompletionAt(variant, "value.fi").state == completionUnsupported

    let inherited = """type
  Base = object
    base: int
  Child = object of Base
    child: int

proc show(value: Child) =
  value.ch
"""
    check memberCompletionAt(inherited, "value.ch").state == completionUnsupported

    let alias = """type
  Person = object
    name: string
  Alias = Person

proc show(value: Alias) =
  value.na
"""
    check memberCompletionAt(alias, "value.na").state == completionUnsupported

    let unknownLocal = """import std/os
proc show(os: Unknown) =
  os.walkD
"""
    check memberCompletionAt(unknownLocal, "os.walkD").state == completionUnsupported

    let nestedReference = """type
  Person = object
    name: string

proc show(value: ref ref Person) =
  value.na
"""
    check memberCompletionAt(nestedReference, "value.na").state == completionUnsupported

    let primitiveArray = """proc show(value: array[4, int]) =
  value.na
"""
    check memberCompletionAt(primitiveArray, "value.na").state == completionUnsupported
