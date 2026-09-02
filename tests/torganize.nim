import std/[os, strutils, unittest]

import onim/organize

const cases = [
  "walkdir", "table", "parsejson", "split", "from", "except", "qualified", "alias",
  "conditional", "conditional_inactive", "included", "multiple", "order", "grouped",
  "grouped_std", "shadowed", "text_only",
]

suite "organize imports":
  for name in cases:
    test name:
      let root = currentSourcePath().parentDir.parentDir
      let beforePath = root / "tests" / "before" / (name & ".nim")
      let afterPath = root / "tests" / "after" / (name & ".nim")
      let before = readFile(beforePath)
      let expected = readFile(afterPath)
      let actual = applyEdits(before, organizeSource(beforePath, before))
      check actual == expected

  test "preserves BOM, CRLF, and a missing final newline":
    let root = currentSourcePath().parentDir.parentDir
    let path = root / "tests" / "before" / "walkdir.nim"
    let before =
      "\xEF\xBB\xBF# header\r\n\r\nfor k, v in walkDir(\"/tmp\"):\r\n  echo k"
    let expected =
      "\xEF\xBB\xBF# header\r\n\r\nimport std/os\r\n\r\nfor k, v in walkDir(\"/tmp\"):\r\n  echo k"
    let actual = applyEdits(before, organizeSource(path, before))
    check actual == expected

  test "can render the legacy stdlib spelling when requested":
    let root = currentSourcePath().parentDir.parentDir
    let path = root / "tests" / "before" / "walkdir.nim"
    var options = defaultOrganizeOptions()
    options.useStdPrefix = false
    let before = readFile(path)
    let actual = applyEdits(before, organizeSource(path, before, options))
    check actual.contains("import os\n\n")

  test "keeps grouped stdlib modules valid in legacy spelling":
    let root = currentSourcePath().parentDir.parentDir
    let path = root / "tests" / "before" / "grouped_std.nim"
    var options = defaultOrganizeOptions()
    options.useStdPrefix = false
    let before = readFile(path)
    let expected = readFile(root / "tests" / "after" / "grouped_std.nim").replace(
        "import std/[os, strformat]", "import os\nimport strformat"
      )
    check applyEdits(before, organizeSource(path, before, options)) == expected

  test "groups multiple new stdlib modules in one edit":
    let root = currentSourcePath().parentDir.parentDir
    let path = root / "tests" / "before" / "multiple.nim"
    let before = readFile(path)
    let edits = organizeSource(path, before)
    check edits.len == 1
    check applyEdits(before, edits) ==
      readFile(root / "tests" / "after" / "multiple.nim")

  test "merges new stdlib modules into one existing import edit":
    let root = currentSourcePath().parentDir.parentDir
    let path = root / "tests" / "before" / "grouped_std.nim"
    let before = readFile(path)
    let edits = organizeSource(path, before)
    check edits.len == 1
    check applyEdits(before, edits) ==
      readFile(root / "tests" / "after" / "grouped_std.nim")
