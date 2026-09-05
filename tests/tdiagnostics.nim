import std/[unittest]

import onim/index/source_index
import onim/index/symbols
import onim/index/surfaces
import onim/semantic/native_diagnostics
import onim/stdlib/map

suite "native diagnostics":
  test "ignores balanced delimiters in comments and strings":
    let index = indexSource("# ( [ ] )\n" & "proc main() =\n" & "  echo \"([)]\"\n")
    check nativeSyntaxDiagnostics(index).len == 0

  test "reports an unterminated string":
    let source = "echo \"unterminated\n"
    let diagnostics = nativeSyntaxDiagnostics(indexSource(source))
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeUnclosedString
    check diagnostics[0].startOffset == source.find('"')

  test "reports unexpected and unclosed delimiters":
    let source = "proc main(] = discard\n"
    let diagnostics = nativeSyntaxDiagnostics(indexSource(source))
    check diagnostics.len == 2
    check diagnostics[0].kind == nativeUnexpectedDelimiter
    check diagnostics[1].kind == nativeUnclosedDelimiter

  test "reports malformed identifier spans":
    var index = indexSource("echo value\n")
    var token = index.parsed.tokens[1]
    token.endOffset = token.endOffset + 1
    index.parsed.tokens = index.parsed.tokens.withToken(1, token)
    let diagnostics = nativeSyntaxDiagnostics(index)
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeMalformedIdentifier

  test "keeps missing-name diagnostics with syntax diagnostics":
    var index = indexSource("proc main() =\n  discard walkDir(\"/tmp\")\n")
    var token = index.parsed.tokens[1]
    token.endOffset = token.endOffset + 1
    index.parsed.tokens = index.parsed.tokens.withToken(1, token)
    let diagnostics = nativeDiagnostics(index, loadStdlibMap(""))
    check diagnostics.len == 2
    check diagnostics[0].kind == nativeMalformedIdentifier
    check diagnostics[1].kind == nativeMissingStdlibImport

  test "reports a missing stdlib import from an unqualified use":
    let diagnostics = nativeMissingStdlibDiagnostics(
      indexSource(
        "proc main() =\n  for kind, path in walkDir(\"/tmp\"): discard path\n"
      ),
      loadStdlibMap(""),
    )
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeMissingStdlibImport
    check diagnostics[0].module == "std/os"

  test "reports a missing stdlib import from a qualified use":
    let diagnostics = nativeMissingStdlibDiagnostics(
      indexSource("proc main() =\n  discard os.walkDir(\"/tmp\")\n"), loadStdlibMap("")
    )
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeMissingStdlibImport
    check diagnostics[0].module == "std/os"

  test "does not report imported or locally defined names":
    let imported = nativeMissingStdlibDiagnostics(
      indexSource("import std/os\nproc main() =\n  discard walkDir(\"/tmp\")\n"),
      loadStdlibMap(""),
    )
    let local = nativeMissingStdlibDiagnostics(
      indexSource(
        "proc walkDir(path: string) = discard\nproc main() =\n  walkDir(\"/tmp\")\n"
      ),
      loadStdlibMap(""),
    )
    check imported.len == 0
    check local.len == 0

  test "recognizes aliased module exports for qualified and unqualified uses":
    let qualified = nativeDiagnostics(
      indexSource(
        "import std/os as file_system\nproc main() =\n  discard fileSystem.walkDir(\"/tmp\")\n"
      ),
      loadStdlibMap(""),
    )
    let unqualified = nativeDiagnostics(
      indexSource("import std/os as fs\nproc main() =\n  discard walkDir(\"/tmp\")\n"),
      loadStdlibMap(""),
    )
    check qualified.len == 0
    check unqualified.len == 0

  test "keeps unrelated missing names diagnosed with an alias":
    let diagnostics = nativeDiagnostics(
      indexSource("import std/os as fs\nproc main() =\n  discard missingAliasName\n"),
      loadStdlibMap(""),
    )
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeUndeclaredIdentifier
    check diagnostics[0].name == "missingAliasName"

  test "does not use an aliased module through a local shadow":
    let diagnostics = nativeDiagnostics(
      indexSource(
        "import std/os as fs\nproc main(fs: int) =\n  discard fs.walkDir(\"/tmp\")\n"
      ),
      loadStdlibMap(""),
    )
    check diagnostics.len == 0

  test "defers duplicate aliases to the compiler":
    let diagnostics = nativeDiagnostics(
      indexSource(
        "import std/os as fs, std/strformat as f_s\nproc main() =\n  discard fs.walkDir(\"/tmp\")\n"
      ),
      loadStdlibMap(""),
    )
    check diagnostics.len == 0

  test "uses the canonical stdlib candidate for split":
    let diagnostics = nativeMissingStdlibDiagnostics(
      indexSource("proc main() =\n  discard split(\"a b\")\n"), loadStdlibMap("")
    )
    check diagnostics.len == 1
    check diagnostics[0].module == "std/strutils"

  test "reports an unknown unqualified identifier natively":
    let diagnostics = nativeDiagnostics(
      indexSource("proc main() =\n  discard definitelyMissing\n"), loadStdlibMap("")
    )
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeUndeclaredIdentifier
    check diagnostics[0].name == "definitelyMissing"

  test "does not report local bindings or lexical text as undeclared":
    let source = """proc main() =
  block:
    let localValue = 1
    discard localValue
  discard "definitelyMissing"
"""
    let diagnostics = nativeDiagnostics(indexSource(source), loadStdlibMap(""))
    check diagnostics.len == 0

  test "recognizes Nim's implicit result binding":
    let diagnostics = nativeDiagnostics(
      indexSource("proc main(): int =\n  result = 1\n"), loadStdlibMap("")
    )
    check diagnostics.len == 0

  test "reports a missing project import from an unqualified use":
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc provided*() = discard\n"))],
      universeComplete = true,
    )
    check project.valid
    check project.universeIsComplete
    check project.lookupInModule("provider", "provided").kind == surfaceResolved
    let diagnostics = nativeDiagnostics(
      indexSource("proc main() =\n  discard provided()\n"), loadStdlibMap(""), project
    )
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeMissingProjectImport
    check diagnostics[0].module == "provider"

  test "reports a missing project import from a qualified use":
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc provided*() = discard\n"))],
      universeComplete = true,
    )
    let diagnostics = nativeDiagnostics(
      indexSource("proc main() =\n  discard provider.provided()\n"),
      loadStdlibMap(""),
      project,
    )
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeMissingProjectImport
    check diagnostics[0].module == "provider"

  test "does not report a known project import":
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc provided*() = discard\n"))],
      universeComplete = true,
    )
    let diagnostics = nativeDiagnostics(
      indexSource("import provider\nproc main() =\n  discard provided()\n"),
      loadStdlibMap(""),
      project,
    )
    check diagnostics.len == 0

  test "resolves owner-relative qualified project imports":
    let project = buildSurfaceIndex(
      @[
        projectSurfaceInput("pkg/provider", indexSource("proc provided*() = discard\n"))
      ],
      universeComplete = true,
    )
    let missing = nativeDiagnostics(
      indexSource("proc main() =\n  discard provider.provided()\n"),
      loadStdlibMap(""),
      project,
      "pkg/consumer",
    )
    let imported = nativeDiagnostics(
      indexSource("import provider\nproc main() =\n  discard provider.provided()\n"),
      loadStdlibMap(""),
      project,
      "pkg/consumer",
    )
    check missing.len == 1
    check missing[0].kind == nativeMissingProjectImport
    check missing[0].module == "pkg/provider"
    check imported.len == 0

  test "suppresses project and stdlib collisions":
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc split*() = discard\n"))],
      universeComplete = true,
    )
    let diagnostics = nativeDiagnostics(
      indexSource("proc main() =\n  discard split()\n"), loadStdlibMap(""), project
    )
    check diagnostics.len == 0

  test "suppresses ambiguous project candidates":
    let project = buildSurfaceIndex(
      @[
        projectSurfaceInput("first", indexSource("proc answer*() = discard\n")),
        projectSurfaceInput("second", indexSource("proc answer*() = discard\n")),
      ],
      universeComplete = true,
    )
    let diagnostics = nativeDiagnostics(
      indexSource("proc main() =\n  discard answer()\n"), loadStdlibMap(""), project
    )
    check diagnostics.len == 0

  test "suppresses uncertain project candidates":
    let project = buildSurfaceIndex(
      @[
        SurfaceInput(
          module: "provider",
          origin: surfaceProject,
          uncertainty: {surfaceConditional},
          exports:
            @[SurfaceExportInput(name: "answer", kind: symbolProc, kindKnown: true)],
        )
      ],
      universeComplete = true,
    )
    let diagnostics = nativeDiagnostics(
      indexSource("proc main() =\n  discard answer()\n"), loadStdlibMap(""), project
    )
    check diagnostics.len == 0
