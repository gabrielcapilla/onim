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

  test "matches UFCS members by named sequence element":
    let source = """type Item = object
type Other = object

proc itemCount*(items: seq[Item]) = discard
proc otherCount*(items: seq[Other]) = discard

proc showItems(items: seq[Item]) =
  items.itemC
proc showOther(items: seq[Other]) =
  items.otherC
"""
    let itemResult = memberCompletionAt(source, "items.itemC")
    check itemResult.state == completionAvailable
    check itemResult.items.mapIt(it.label) == @["itemCount"]
    let otherResult = memberCompletionAt(source, "items.otherC")
    check otherResult.state == completionAvailable
    check otherResult.items.mapIt(it.label) == @["otherCount"]

  test "completes fields of indexed named sequence elements":
    let source = """type User = object
  name: string

proc show(users: seq[User]) =
  users[0].na
"""
    let result = memberCompletionAt(source, "users[0].na")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["name"]

  test "completes fields of indexed named array elements":
    let source = """type User = object
  name: string

proc show(users: array[2, User]) =
  users[0].na
"""
    let result = memberCompletionAt(source, "users[0].na")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["name"]

  test "completes simple enum members through the type name":
    let source = """type Color = enum
  red, green, blue

proc show() =
  Color.gr
"""
    let result = memberCompletionAt(source, "Color.gr")
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["green"]

    let shadowed = """type Color = enum
  red, green

proc show(Color: int) =
  Color.gr
    """
    check memberCompletionAt(shadowed, "Color.gr").state == completionUnsupported

  test "completes exported enum members through a project import":
    let root = getTempDir() / ("onim-enum-completion-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-enum-completion-cache-" & $getCurrentProcessId())
    createDir(root)
    let providerPath = root / "colors.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "type Color* = enum\n  red, green, blue\n")
    let consumer = "import colors\n\nproc show() =\n  Color.gr\n"
    writeFile(consumerPath, consumer)
    let previous = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previous.len > 0:
        putEnv("ONIM_CACHE_DIR", previous)
      else:
        delEnv("ONIM_CACHE_DIR")
      removeFile(providerPath)
      removeFile(consumerPath)
      removeDir(root)
      if dirExists(cacheRoot):
        removeDir(cacheRoot)
    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let snapshot = workspace.snapshotForFile(workspace.fileIdForPath(consumerPath))
    let result = completeAt(
      workspace, snapshot, consumer.find("Color.gr") + "Color.gr".len, emptyStdlibMap()
    )
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["green"]
    let fromConsumer = "from colors import Color\n\nproc show() =\n  Color.gr\n"
    discard
      workspace.changeDocument("file://" & consumerPath, consumerPath, fromConsumer, 2)
    let fromSnapshot = workspace.snapshotForFile(workspace.fileIdForPath(consumerPath))
    let fromResult = completeAt(
      workspace,
      fromSnapshot,
      fromConsumer.find("Color.gr") + "Color.gr".len,
      emptyStdlibMap(),
    )
    check fromResult.state == completionAvailable
    check fromResult.items.mapIt(it.label) == @["green"]

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

    let multiGeneric = """type
  Pair[A, B] = object
    left: A
    right: B

proc show(value: Pair[int, string]) =
  value.le
"""
    let multiGenericResult = memberCompletionAt(multiGeneric, "value.le")
    check multiGenericResult.state == completionAvailable
    check multiGenericResult.items.mapIt(it.label) == @["left"]

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

  test "completes project generic UFCS members":
    let root = getTempDir() / ("onim-generic-ufcs-" & $getCurrentProcessId())
    if dirExists(root):
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(
      providerPath,
      """type Box*[T] = object
  value: T

proc first*(box: Box[int]): int = discard

type Pair*[A, B] = object
  left: A
  right: B

proc pairFirst*(pair: Pair[int, string]): int = discard
proc pairBool*(pair: Pair[int, bool]): int = discard
""",
    )
    let consumer = """import provider
proc show(value: provider.Box[int]) =
  value.fi
proc showString(value: provider.Box[string]) =
  value.fi
proc showPair(value: provider.Pair[int, string]) =
  value.pa
proc showPairBool(value: provider.Pair[int, bool]) =
  value.pa
"""
    writeFile(consumerPath, consumer)
    defer:
      for path in [providerPath, consumerPath]:
        if fileExists(path):
          removeFile(path)
      removeDir(root)

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let snapshot = workspace.snapshotForFile(workspace.fileIdForPath(consumerPath))
    let result = completeAt(
      workspace, snapshot, consumer.find("value.fi") + "value.fi".len, loadStdlibMap("")
    )
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["first"]
    let stringResult = completeAt(
      workspace,
      snapshot,
      consumer.find("value.fi", consumer.find("showString")) + "value.fi".len,
      loadStdlibMap(""),
    )
    check stringResult.state == completionUnsupported
    let pairResult = completeAt(
      workspace, snapshot, consumer.find("value.pa") + "value.pa".len, loadStdlibMap("")
    )
    check pairResult.state == completionAvailable
    check pairResult.items.mapIt(it.label) == @["pairFirst"]
    let mismatchResult = completeAt(
      workspace,
      snapshot,
      consumer.find("value.pa", consumer.find("showPairBool")) + "value.pa".len,
      loadStdlibMap(""),
    )
    check mismatchResult.state == completionAvailable
    check mismatchResult.items.mapIt(it.label) == @["pairBool"]
