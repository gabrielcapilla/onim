import std/[strutils, unittest]

import onim/features/hover
import onim/session/workspace
import onim/stdlib/map

proc hoverFor(source, wanted: string): HoverInfo =
  let workspace = initWorkspace()
  let path = "/tmp/onim-hover-test.nim"
  let uri = "file:///tmp/onim-hover-test.nim"
  discard workspace.openDocument(uri, path, source, 1)
  let snapshot = workspace.snapshotForDocument(uri, path)
  resolveHover(workspace, snapshot, source.rfind(wanted) + 1, stdlibMap())

suite "native hover":
  test "resolves imported stdlib names":
    let info = hoverFor("import std/os\nwalkDir(\"/tmp\")\n", "walkDir")
    check info.state == hoverAvailable
    check info.module == "std/os"

  test "resolves qualified aliases":
    let info =
      hoverFor("import std/os as filesystem\nfilesystem.walkDir(\"/tmp\")\n", "walkDir")
    check info.state == hoverAvailable
    check info.module == "std/os"

  test "resolves from bindings":
    let info = hoverFor("from std/os import walkDir\nwalkDir(\"/tmp\")\n", "walkDir")
    check info.state == hoverAvailable
    check info.module == "std/os"

  test "does not guess conditional or missing imports":
    let conditional =
      hoverFor("when defined(posix):\n  import std/os\nwalkDir(\"/tmp\")\n", "walkDir")
    check conditional.state == hoverUnavailable
    let missing = hoverFor("walkDir(\"/tmp\")\n", "walkDir")
    check missing.state == hoverUnavailable

  test "prefers a local definition over the stdlib map":
    let info = hoverFor("proc walkDir() = discard\nwalkDir()\n", "walkDir")
    check info.state == hoverAvailable
    check info.module.len == 0
