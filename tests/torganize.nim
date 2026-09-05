import std/[os, strutils, unittest]

import onim/features/organize
import onim/index/occurrences
import onim/index/source_index
import onim/index/surfaces
import onim/semantic/compiler_api
import onim/session/ids
import onim/session/module_catalog
import onim/stdlib/map

const cases = [
  "walkdir", "table", "parsejson", "split", "from", "except", "qualified", "alias",
  "conditional", "conditional_inactive", "included", "multiple", "order", "grouped",
  "grouped_std", "unused", "unused_grouped", "unused_from", "unused_separate",
  "shadowed", "unused_from_empty", "unused_except", "unused_keep", "unused_all",
  "text_only",
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

  test "retains compiler unused declaration hints":
    let root = currentSourcePath().parentDir.parentDir
    let path = root / "tests" / "before" / "unused.nim"
    var foundUnusedImport = false
    var foundUnusedDeclaration = false
    for diagnostic in checkFileCached(path, path):
      foundUnusedImport = foundUnusedImport or diagnostic.isUnusedImport
      foundUnusedDeclaration = foundUnusedDeclaration or diagnostic.isUnusedDeclaration
    check foundUnusedImport
    check foundUnusedDeclaration

  test "uses the source index for a compiler-free no-op":
    let source = "# comments and strings contain no source uses\n\"walkDir\"\n"
    let index = indexSource(source)
    check index.occurrences.isComplete
    check organizeSourceWithIndex("/no/such/file.nim", source, index).len == 0

  test "uses the indexed stdlib surface for compiler-free additions":
    let source =
      "proc main() =\n" & "  echo fmt(\"hi\")\n" & "  for k, v in walkDir(\"/tmp\"):\n" &
      "    discard k\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check attempt.edits.len == 1
    check applyEdits(source, attempt.edits) == "import std/[os, strformat]\n\n" & source

  test "organizeSource uses the native index before compiler fallback":
    let source = "for k, v in walkDir(\"/tmp\"):\n  discard k\n"
    let edits = organizeSource("/no/such/file.nim", source)
    check applyEdits(source, edits) == "import std/os\n\n" & source

  test "resolves Nim identifier style in the indexed stdlib surface":
    let source = "echo parse_json(\"{}\")\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check applyEdits(source, attempt.edits) == "import std/json\n\n" & source

  test "resolves a qualified indexed stdlib use":
    let source = "for kind, path in os.walkDir(\"/tmp\"):\n  discard kind\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check applyEdits(source, attempt.edits) == "import std/os\n\n" & source

  test "does not duplicate a style-insensitive from binding":
    let source = "from std/json import parse_json\n" & "\n" & "echo parseJson(\"{}\")\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check attempt.edits.len == 0

  test "falls back when a local declaration can shadow an indexed stdlib name":
    let source = "proc walkDir() = discard\n" & "proc main() =\n" & "  walkDir()\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check not attempt.handled
    check attempt.edits.len == 0

  test "keeps a used indexed stdlib import without compiler validation":
    let source =
      "import std/os\n" & "\n" & "proc main() =\n" & "  discard walkDir(\"/tmp\")\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check attempt.edits.len == 0

  test "removes unused indexed stdlib imports without compiler validation":
    let root = currentSourcePath().parentDir.parentDir
    for name in ["unused", "unused_grouped", "unused_from", "unused_separate"]:
      let before = readFile(root / "tests" / "before" / (name & ".nim"))
      let expected = readFile(root / "tests" / "after" / (name & ".nim"))
      let index = indexSource(before)
      let attempt = tryOrganizeSourceWithIndex(
        "/no/such/file.nim", before, index, loadStdlibMap("")
      )
      check attempt.handled
      check applyEdits(before, attempt.edits) == expected

  test "removes unused names from an external from import without compiler validation":
    let source =
      "from project/module import unusedName, usedName\n" & "\necho usedName()\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check applyEdits(source, attempt.edits) ==
      "from project/module import usedName\n" & "\necho usedName()\n"

  test "combines native additions with removals":
    let source = "import std/os\n\necho fmt(\"hi\")\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check applyEdits(source, attempt.edits) ==
      "import std/strformat\n\necho fmt(\"hi\")\n"

  test "keeps a native module for unknown qualified members":
    let source = "import std/os\n\ndiscard os.someFutureMember()\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check attempt.edits.len == 0

  test "uses a complete project surface for native additions":
    let source = "proc main() =\n  discard provided()\n"
    let index = indexSource(source)
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc provided*() = discard\n"))],
      universeComplete = true,
    )
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      source,
      index,
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "",
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) == "import provider\n\n" & source

  test "uses the owner-relative project module for qualified additions":
    let source = "provider.provided()\n"
    let index = indexSource(source)
    let project = buildSurfaceIndex(
      @[
        projectSurfaceInput("pkg/provider", indexSource("proc provided*() = discard\n"))
      ],
      universeComplete = true,
    )
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      source,
      index,
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "pkg/consumer",
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) == "import pkg/provider\n\n" & source

  test "uses a complete module catalog for project additions":
    let root = getTempDir() / ("onim-organize-project-" & $getCurrentProcessId())
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "proc provided*() = discard\n")
    defer:
      if fileExists(providerPath):
        removeFile(providerPath)
      if fileExists(consumerPath):
        removeFile(consumerPath)
      if dirExists(root):
        removeDir(root)
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource(readFile(providerPath)))],
      universeComplete = true,
    )
    let catalog = buildModuleCatalog(
      root,
      @[
        ModuleFile(id: ids.FileId(1), path: providerPath),
        ModuleFile(id: ids.FileId(2), path: consumerPath),
      ],
    )
    check catalog.complete
    check catalog.resolveModuleName("consumer", "provider").kind == moduleResolved
    check project.resolveSurfaceReference(catalog, "provided", "provider", "consumer").kind ==
      surfaceResolved
    let source = "provider.provided()\n"
    let attempt = tryOrganizeSourceWithIndex(
      consumerPath,
      source,
      indexSource(source),
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      catalog,
      "consumer",
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) == "import provider\n\n" & source

  test "removes an unused complete project import natively":
    let source = "import provider\n\nproc main() =\n  discard\n"
    let index = indexSource(source)
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc provided*() = discard\n"))],
      universeComplete = true,
    )
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      source,
      index,
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "",
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) == "proc main() =\n  discard\n"

  test "falls back for ambiguous project providers":
    let source = "discard provided()\n"
    let index = indexSource(source)
    let project = buildSurfaceIndex(
      @[
        projectSurfaceInput("first", indexSource("proc provided*() = discard\n")),
        projectSurfaceInput("second", indexSource("proc provided*() = discard\n")),
      ],
      universeComplete = true,
    )
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      source,
      index,
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "",
    )
    check not attempt.handled
    check attempt.edits.len == 0

  test "falls back for project and stdlib name collisions":
    let source = "discard split(\"a b\")\n"
    let index = indexSource(source)
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc split*() = discard\n"))],
      universeComplete = true,
    )
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      source,
      index,
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "",
    )
    check not attempt.handled
    check attempt.edits.len == 0

  test "keeps diagnostic locations when paths contain parentheses":
    let root = getTempDir() / ("onim-(diagnostic)-" & $getCurrentProcessId())
    createDir(root)
    let path = root / "location.nim"
    writeFile(path, "echo missingLocationName\n")
    defer:
      if fileExists(path):
        removeFile(path)
      if dirExists(root):
        removeDir(root)
    var found = false
    for diagnostic in compilerDiagnostics(path):
      if diagnostic.name == "missingLocationName":
        found = true
        check absolutePath(diagnostic.file) == absolutePath(path)
    check found
