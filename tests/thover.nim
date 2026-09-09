import std/[os, strutils, unittest]

import onim/features/hover
import onim/index/bindings
import onim/index/scopes
import onim/session/workspace
import onim/stdlib/map
import onim/stdlib/map_runtime
import onim/syntax/tokens

proc hoverFor(source, wanted: string): HoverInfo =
  let workspace = initWorkspace()
  let path = "/tmp/onim-hover-test.nim"
  let uri = "file:///tmp/onim-hover-test.nim"
  discard workspace.openDocument(uri, path, source, 1)
  let snapshot = workspace.snapshotForDocument(uri, path)
  resolveHover(workspace, snapshot, source.rfind(wanted) + 1, stdlibMap())

proc hoverAt(source: string, byteOffset: int): HoverInfo =
  let workspace = initWorkspace()
  let path = "/tmp/onim-hover-test.nim"
  let uri = "file:///tmp/onim-hover-test.nim"
  discard workspace.openDocument(uri, path, source, 1)
  let snapshot = workspace.snapshotForDocument(uri, path)
  resolveHover(workspace, snapshot, byteOffset, stdlibMap())

suite "native hover":
  test "resolves imported stdlib names":
    let info = hoverFor("import std/os\nwalkDir(\"/tmp\")\n", "walkDir")
    check info.state == hoverAvailable
    check info.module == "std/os"
    check info.documentation.contains("Walks over")

  test "renders stdlib documentation as readable markdown":
    let info = hoverFor("import std/strformat\nfmt(\"hi\")\n", "fmt")
    check info.state == hoverAvailable
    check info.documentation.contains("dummy untyped")
    check info.documentation.contains("`fmt`")
    check not info.documentation.contains("<tt")

  test "resolves hover for an explicitly typed stdlib receiver":
    let source = """import std/httpclient
proc main() =
  var client: HttpClient
  client.get
"""
    let info = hoverAt(source, source.find("client.get") + "client.".len)
    check info.state == hoverAvailable
    check info.name == "get"
    check info.module == "std/httpclient"
    check info.signature.contains("get")
    check info.documentation.len > 0

  test "resolves implicit stdlib File values":
    let info = hoverFor("proc show() = discard stdout\n", "stdout")
    check info.state == hoverAvailable
    check info.module == "std/syncio"
    check info.signature.endsWith(": File")
    check info.documentation == "The standard output stream."

  test "shows contiguous project declaration documentation":
    let source =
      "## Say hello.\n## This line continues the contract.\nproc greet*() = discard\ngreet()\n"
    let info = hoverFor(source, "greet")
    check info.state == hoverAvailable
    check info.documentation == "Say hello.\nThis line continues the contract."

  test "shows leading body comments when a declaration has no doc comment":
    let source =
      "proc main() =\n" & "  # Main function with a simple comment\n" &
      "  ## Main function with a docstring\n" & "  discard\n"
    let info = hoverFor(source, "main")
    check info.state == hoverAvailable
    check info.documentation ==
      "Main function with a simple comment\nMain function with a docstring"

  test "resolves qualified aliases":
    let info =
      hoverFor("import std/os as filesystem\nfilesystem.walkDir(\"/tmp\")\n", "walkDir")
    check info.state == hoverAvailable
    check info.module == "std/os"

  test "resolves from bindings":
    let info = hoverFor("from std/os import walkDir\nwalkDir(\"/tmp\")\n", "walkDir")
    check info.state == hoverAvailable
    check info.module == "std/os"

  test "resolves proven Linux conditionals and rejects unknown imports":
    let conditional =
      hoverFor("when defined(posix):\n  import std/os\nwalkDir(\"/tmp\")\n", "walkDir")
    check conditional.state == hoverAvailable
    check conditional.module == "std/os"
    let inactive = hoverFor(
      "when defined(windows):\n  import std/os\nwalkDir(\"/tmp\")\n", "walkDir"
    )
    check inactive.state == hoverUnavailable
    let unknown = hoverFor(
      "when defined(enableOs):\n  import std/os\nwalkDir(\"/tmp\")\n", "walkDir"
    )
    check unknown.state == hoverUnavailable
    let missing = hoverFor("walkDir(\"/tmp\")\n", "walkDir")
    check missing.state == hoverUnavailable

  test "prefers a local definition over the stdlib map":
    let info = hoverFor("proc walkDir() = discard\nwalkDir()\n", "walkDir")
    check info.state == hoverAvailable
    check info.module.len == 0

  test "resolves native object field hover":
    let source = """type Person = object
  display_name*: string

proc show(person: Person) =
  discard person.displayName
"""
    let info = hoverFor(source, "displayName")
    check info.state == hoverAvailable
    check info.name == "display_name"
    check info.kind == "field"
    check info.module.len == 0

  test "resolves inferred named tuple field hover":
    let source = """proc show() =
  let point = (x: 1, y: "ok")
  discard point.x
"""
    let info = hoverAt(source, source.rfind("x"))
    check info.state == hoverAvailable
    check info.name == "x"
    check info.kind == "field"

  test "resolves named tuple element field hover":
    let source = """proc show() =
  let people = @[(name: "Ada", age: 1), (name: "Bob", age: 2)]
  discard people[0].name
"""
    let info = hoverAt(source, source.rfind("people[0].name") + "people[0].".len)
    check info.state == hoverAvailable
    check info.name == "name"
    check info.kind == "field"

  test "reports explicit, constructor, and literal local types":
    let source = """type Person = object
  name: string

proc show(value: ref Person) =
  let made = Person()
  let flag = true
  var character = 'x'
  const text = "hello"
  let count = 42
  let ratio = 3.14
  let mask = 0xE
  let numbers = @[1, 2, 3]
  discard value
  discard made
  discard flag
  discard character
  discard text
  discard count
  discard ratio
  discard mask
  discard numbers
"""
    check hoverFor(source, "value").signature == "value: ref Person"
    check hoverFor(source, "made").signature == "let made: Person"
    check hoverFor(source, "flag").signature == "let flag: bool"
    check hoverFor(source, "character").signature == "var character: char"
    check hoverFor(source, "text").signature == "const text: string"
    check hoverFor(source, "count").signature == "let count: int"
    check hoverFor(source, "ratio").signature == "let ratio: float"
    check hoverFor(source, "mask").signature == "let mask: int"
    check hoverFor(source, "numbers").signature == "let numbers: seq[int]"

  test "reports explicit primitive sequence annotations":
    let source = """proc show() =
  let numbers: seq[int] = @[]
  discard numbers
"""
    check hoverFor(source, "numbers").signature == "let numbers: seq[int]"

  test "reports explicit primitive array annotations":
    let source = """proc show() =
  let values: array[4, int] = default(array[4, int])
  discard values
"""
    check hoverFor(source, "values").signature == "let values: array[4, int]"

  test "keeps array-return calls and array literals conservative":
    let source = """proc make(): array[3, int] = default(array[3, int])

proc show() =
  let values = make()
  let literal = [1, 2]
  discard values
  discard literal
"""
    check hoverFor(source, "values").signature.len == 0
    check hoverFor(source, "literal").signature.len == 0

  test "propagates direct procedure and function return types":
    let source = """type Person = object
  name: string

proc makePerson(): Person = discard
func makeText(): string = "hello"
proc infer() = discard

proc show() =
  let person = makePerson()
  let text = makeText()
  let unknown = infer()
  discard person
  discard text
  discard unknown
"""
    check hoverFor(source, "person").signature == "let person: Person"
    check hoverFor(source, "text").signature == "let text: string"
    let unknown = hoverFor(source, "unknown")
    check unknown.state == hoverAvailable
    check unknown.name == "unknown"
    check unknown.signature.len == 0

  test "propagates a project procedure return type":
    let root = getTempDir() / ("onim-hover-return-" & $getCurrentProcessId())
    if dirExists(root):
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let provider = """type Person* = object
  name*: string

proc makePerson*(): Person = discard
"""
    let consumer = """import provider as model
proc show() =
  let person = model.makePerson()
  discard person
"""
    writeFile(providerPath, provider)
    writeFile(consumerPath, consumer)
    defer:
      if fileExists(providerPath):
        removeFile(providerPath)
      if fileExists(consumerPath):
        removeFile(consumerPath)
      if dirExists(root):
        removeDir(root)
    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    let snapshot = workspace.snapshotForFile(workspace.fileIdForPath(consumerPath))
    let info =
      resolveHover(workspace, snapshot, consumer.find("person") + 1, stdlibMap())
    check info.state == hoverAvailable
    check info.signature == "let person: Person"

  test "keeps unsupported local inference conservative":
    let source = """proc show() =
  let unary = -1
  let floating = 1.0
  let prefixed = r"raw"
  let missing = nil
  let compound = 1 + 2
  let mixed = @[1, "x"]
  let empty = @[]
  discard unary
  discard floating
  discard prefixed
  discard missing
  discard compound
  discard mixed
  discard empty
"""
    check hoverFor(source, "floating").signature == "let floating: float"
    for name in ["unary", "prefixed", "missing", "compound", "mixed", "empty"]:
      let info = hoverFor(source, name)
      check info.state == hoverAvailable
      check info.name == name
      check info.signature.len == 0

  test "keeps numeric suffixes in one literal and preserves later bindings":
    let source = """proc show() =
  let suffixed = 1'i32
  let byteValue = 1'u8
  let ratioValue = 1.0'f32
  let later = 42
  discard suffixed
  discard byteValue
  discard ratioValue
  discard later
"""
    let path = "/tmp/onim-hover-suffixed.nim"
    let uri = "file:///tmp/onim-hover-suffixed.nim"
    let workspace = initWorkspace()
    discard workspace.openDocument(uri, path, source, 1)
    let snapshot = workspace.snapshotForDocument(uri, path)
    check snapshot.index.bindingsReady
    check lexicalIssues(snapshot.index.parsed.tokens).len == 0
    check resolveHover(workspace, snapshot, source.rfind("suffixed") + 1, stdlibMap()).signature ==
      "let suffixed: int32"
    check resolveHover(workspace, snapshot, source.rfind("byteValue") + 1, stdlibMap()).signature ==
      "let byteValue: uint8"
    check resolveHover(workspace, snapshot, source.rfind("ratioValue") + 1, stdlibMap()).signature ==
      "let ratioValue: float32"
    check resolveHover(workspace, snapshot, source.rfind("later") + 1, stdlibMap()).signature ==
      "let later: int"

  test "keeps typed hover bound to the nearest shadow":
    let source = """proc show() =
  let item = 1
  block:
    let item = "inner"
    discard item
  discard item
"""
    let innerOffset = source.find("discard item") + "discard ".len + 1
    let outerOffset = source.rfind("discard item") + "discard ".len + 1
    check hoverAt(source, innerOffset).signature == "let item: string"
    check hoverAt(source, outerOffset).signature == "let item: int"

  test "revalidates equal-length incremental literal edits":
    let oldSource = """proc show() =
  let flag = true
  discard flag
"""
    let newSource = oldSource.replace("true", "name")
    let path = "/tmp/onim-hover-incremental.nim"
    let uri = "file:///tmp/onim-hover-incremental.nim"
    let workspace = initWorkspace()
    discard workspace.openDocument(uri, path, oldSource, 1)
    let oldSnapshot = workspace.snapshotForDocument(uri, path)
    let oldInfo =
      resolveHover(workspace, oldSnapshot, oldSource.rfind("flag") + 1, stdlibMap())
    discard workspace.changeDocument(uri, path, newSource, 2)
    let updatedSnapshot = workspace.snapshotForDocument(uri, path)
    let updatedInfo =
      resolveHover(workspace, updatedSnapshot, newSource.rfind("flag") + 1, stdlibMap())
    let freshWorkspace = initWorkspace()
    discard freshWorkspace.openDocument(uri, path, newSource, 1)
    let freshSnapshot = freshWorkspace.snapshotForDocument(uri, path)
    let freshInfo = resolveHover(
      freshWorkspace, freshSnapshot, newSource.rfind("flag") + 1, stdlibMap()
    )
    check oldInfo.signature == "let flag: bool"
    check updatedInfo.signature.len == 0
    check updatedInfo.signature == freshInfo.signature
