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

  test "keeps implicit-only edits native while project surface is incomplete":
    let project = buildSurfaceIndex(
      @[projectSurfaceInput("provider", indexSource("proc provided*() = discard\n"))],
      universeComplete = false,
    )
    let implicitSource = "proc main() =\n  echo 1'u8\n"
    let implicitAttempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      implicitSource,
      indexSource(implicitSource),
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "",
    )
    check implicitAttempt.handled
    check implicitAttempt.edits.len == 0

    let projectSource = "proc main() =\n  discard provided()\n"
    let projectAttempt = tryOrganizeSourceWithIndex(
      "/no/such/file.nim",
      projectSource,
      indexSource(projectSource),
      loadStdlibMap(""),
      defaultOrganizeOptions(),
      project,
      nil,
      "",
    )
    check not projectAttempt.handled

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
