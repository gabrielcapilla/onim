import std/[os, strutils, unittest]

import onim/features/organize
import onim/features/organize_edits
import onim/index/cache
import onim/index/occurrences
import onim/index/source_index
import onim/index/surfaces
import onim/index/surface_project_input
import onim/index/surface_resolution
import onim/semantic/compiler_api
import onim/session/ids
import onim/session/module_catalog
import onim/stdlib/map

suite "organize imports":
  test "retains compiler unused declaration hints":
    let root = currentSourcePath().parentDir.parentDir.parentDir
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

  test "recognizes macro string literal prefixes":
    let source =
      "let w: string = \"World\"\n" & "let n: uint8 = 99\n" & "proc main() =\n" &
      "  stdout.writeLine fmt\"Hello, {w} {n}\"\n" & "proc listFiles(d: string) =\n" &
      "  for k, p in walkDir(d):\n" & "    echo p\n"
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
    )
    check attempt.handled
    check attempt.edits.len == 1
    check applyEdits(source, attempt.edits) == "import std/[os, strformat]\n\n" & source

  test "organizeSource uses the native index before compiler fallback":
    let source = "for k, v in walkDir(\"/tmp\"):\n  discard k\n"
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) == "import std/os\n\n" & source
    let edits = organizeSource("/no/such/file.nim", source)
    check applyEdits(source, edits) == "import std/os\n\n" & source

  test "keeps the native path for a commented module header":
    let source = "# header\n\nfor k, v in walkDir(\"/tmp\"):\n  discard k\n"
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) ==
      "# header\n\nimport std/os\n\nfor k, v in walkDir(\"/tmp\"):\n  discard k\n"

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

  test "handles plain stdlib aliases natively":
    for source in [
      "import std/os as fs\n\nproc main() =\n  discard fs.walkDir(\"/tmp\")\n",
      "import std/os as file_system\n\nproc main() =\n  discard fileSystem.walkDir(\"/tmp\")\n",
      "import std/os as fs\n\nproc main() =\n  discard walkDir(\"/tmp\")\n",
      "import std/os as fs\n\nproc main() =\n  discard fs.walkDir(\"/tmp\").path\n",
      "import std/os as fs, std/strformat as format_tools\n\nproc main() =\n  discard fs.walkDir(\"/tmp\")\n  discard format_tools.fmt(\"hi\")\n",
    ]:
      let attempt = tryOrganizeSourceWithIndex(
        "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
      )
      check attempt.handled
      check attempt.edits.len == 0

  test "removes an unused aliased module natively":
    let source = "import std/os as fs\n\nproc main() =\n  discard\n"
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) == "proc main() =\n  discard\n"

  test "keeps an aliased project module natively":
    let source = "import provider as data_provider\n\ndata_provider.provided()\n"
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc provided*() = discard\n"))],
      universeComplete = true,
    )
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      source,
      indexSource(source),
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "",
    )
    check attempt.handled
    check attempt.edits.len == 0

  test "falls back for ambiguous or unsupported aliases":
    for source in [
      "import std/os as fs, std/strformat as f_s\n\ndiscard fs.walkDir(\"/tmp\")\n",
      "when defined(enableOs):\n  import std/os as fs\n\ndiscard fs.walkDir(\"/tmp\")\n",
      "import std/os as fs except walkDir\n\ndiscard fs.walkDir(\"/tmp\")\n",
    ]:
      let attempt = tryOrganizeSourceWithIndex(
        "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
      )
      check not attempt.handled
      check attempt.edits.len == 0

  test "handles exact Linux conditional imports without rewriting them":
    let active =
      "when defined(posix):\n  import std/os as fs\n\ndiscard fs.walkDir(\"/tmp\")\n"
    let activeAttempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", active, indexSource(active), loadStdlibMap("")
    )
    check activeAttempt.handled
    check activeAttempt.edits.len == 0

    let inactive = "when defined(windows):\n  import std/os as fs\n\ndiscard\n"
    let inactiveAttempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", inactive, indexSource(inactive), loadStdlibMap("")
    )
    check inactiveAttempt.handled
    check inactiveAttempt.edits.len == 0

  test "adds imports used in a main-module conditional":
    let source = "when isMainModule:\n  for k, v in walkDir(\"/tmp\"):\n    discard v\n"
    let actual = applyEdits(source, organizeSource("/no/such/file.nim", source))
    check actual == "import std/os\n\n" & source

  test "does not split an indented conditional import":
    let source =
      "when isMainModule:\n  import std/strformat\n  for k, v in walkDir(\"/tmp\"):\n    discard v\n"
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
    )
    check not attempt.handled
    check attempt.edits.len == 0
    check applyEdits(source, organizeSource("/no/such/file.nim", source)) == source

  test "does not treat a local alias shadow as module use":
    let source = "import std/os as fs\n\nproc main(fs: int) =\n  discard fs\n"
    let attempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim", source, indexSource(source), loadStdlibMap("")
    )
    check attempt.handled
    check applyEdits(source, attempt.edits) == "proc main(fs: int) =\n  discard fs\n"

  test "keeps alias organization identical after source index cache reload":
    let root = getTempDir() / ("onim-alias-cache-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-alias-cache-" & $getCurrentProcessId())
    let stdlib = loadStdlibMap("")
    createDir(root)
    let filePath = root / "alias.nim"
    let source = "import std/os as fs\n\necho fmt(\"hi\")\n"
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    let cachePath = cacheFilePath(root, filePath)
    let modulesPath = splitFile(cachePath).dir
    let projectPath = parentDir(modulesPath)
    let versionPath = parentDir(projectPath)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      if fileExists(cachePath):
        removeFile(cachePath)
      if dirExists(modulesPath):
        removeDir(modulesPath)
      if dirExists(projectPath):
        removeDir(projectPath)
      if dirExists(versionPath):
        removeDir(versionPath)
      if dirExists(cacheRoot):
        removeDir(cacheRoot)
      if dirExists(root):
        removeDir(root)

    let directIndex = indexSource(source)
    let direct = tryOrganizeSourceWithIndex(filePath, source, directIndex, stdlib)
    check direct.handled
    check saveCachedSourceIndex(root, filePath, source, directIndex)
    let cachedIndex = loadCachedSourceIndex(root, filePath, source)
    check cachedIndex != nil
    let cached = tryOrganizeSourceWithIndex(filePath, source, cachedIndex, stdlib)
    check cached.handled == direct.handled
    check applyEdits(source, cached.edits) == applyEdits(source, direct.edits)
    let organized = applyEdits(source, direct.edits)
    let second =
      tryOrganizeSourceWithIndex(filePath, organized, indexSource(organized), stdlib)
    check second.handled
    check second.edits.len == 0

  test "keeps a local declaration that shadows an indexed stdlib name natively":
    let source = "proc walkDir() = discard\n" & "proc main() =\n" & "  walkDir()\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
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
    let root = currentSourcePath().parentDir.parentDir.parentDir
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

  test "replaces a stale private stdlib import after correcting a symbol":
    let source =
      "import private/osdirs\n" & "\n" & "proc main() =\n" &
      "  for kind, path in walkDir(\"/tmp\"):\n" & "    discard kind\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check applyEdits(source, attempt.edits) ==
      "import std/os\n\nproc main() =\n" & "  for kind, path in walkDir(\"/tmp\"):\n" &
      "    discard kind\n"

  test "keeps a native module for unknown qualified members":
    let source = "import std/os\n\ndiscard os.someFutureMember()\n"
    let index = indexSource(source)
    let attempt =
      tryOrganizeSourceWithIndex("/no/such/file.nim", source, index, loadStdlibMap(""))
    check attempt.handled
    check attempt.edits.len == 0
