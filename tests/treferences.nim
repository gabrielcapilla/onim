import std/[algorithm, strutils, unittest]
import std/os except FileId

import onim/features/references
import onim/index/source_index
import onim/session/ids
import onim/session/workspace
import onim/session/workspace_models
import onim/syntax/tokens

proc cleanTree(root: string) =
  if not dirExists(root):
    return
  var directories: seq[string] = @[]
  for path in walkDirRec(root):
    if fileExists(path):
      removeFile(path)
    elif dirExists(path):
      directories.add path
  directories.sort(
    proc(left, right: string): int =
      cmp(right.len, left.len)
  )
  for path in directories:
    if dirExists(path):
      removeDir(path)
  if dirExists(root):
    removeDir(root)

proc snapshotFor(text: string): WorkspaceSnapshot =
  let index = indexSource(text)
  WorkspaceSnapshot(
    valid: true,
    id: SnapshotId(1),
    fileId: FileId(1),
    path: "references.nim",
    text: text,
    state: workspaceOpen,
    contentGeneration: ContentGeneration(1),
    dependencyGeneration: DependencyGeneration(1),
    configGeneration: ConfigGeneration(1),
    surfaceGeneration: SurfaceGeneration(1),
    index: index,
  )

proc tokenAt(text: string, snapshot: WorkspaceSnapshot, offset: int): uint32 =
  uint32(tokenAtOffset(snapshot.index.parsed.tokens, offset))

proc referenceOffsets(text, name: string): seq[int] =
  var cursor = 0
  while true:
    let found = text.find(name, cursor)
    if found < 0:
      break
    result.add found
    cursor = found + name.len

suite "native same-file references":
  test "resolves parameters and direct locals in source order":
    let text = """proc add(value: int) =
  let total = value + 1
  total
"""
    let snapshot = snapshotFor(text)
    let workspace = initWorkspace()
    let offsets = text.referenceOffsets("value")
    let valueReferences = resolveSameFileReferences(
      workspace, snapshot, offsets[1], includeDeclaration = true
    )
    check valueReferences.supported
    check valueReferences.tokens ==
      @[tokenAt(text, snapshot, offsets[0]), tokenAt(text, snapshot, offsets[1])]

    let totalOffsets = text.referenceOffsets("total")
    let totalReferences = resolveSameFileReferences(
      workspace, snapshot, totalOffsets[1], includeDeclaration = false
    )
    check totalReferences.supported
    check totalReferences.tokens == @[tokenAt(text, snapshot, totalOffsets[1])]

  test "matches Nim style-insensitive local names":
    let text = """proc show(foo_bar: int) =
  echo foobar
"""
    let snapshot = snapshotFor(text)
    let offsets = text.referenceOffsets("foo")
    let references = resolveSameFileReferences(
      initWorkspace(), snapshot, text.find("foobar"), includeDeclaration = true
    )
    check references.supported
    check references.tokens ==
      @[
        tokenAt(text, snapshot, offsets[0]),
        tokenAt(text, snapshot, text.find("foobar")),
      ]

  test "keeps same-name locals in separate routines":
    let text = """proc first(value: int) =
  echo value
proc second(value: int) =
  echo value
"""
    let snapshot = snapshotFor(text)
    let offsets = text.referenceOffsets("value")
    let references = resolveSameFileReferences(
      initWorkspace(), snapshot, offsets[1], includeDeclaration = true
    )
    check references.supported
    check references.tokens ==
      @[tokenAt(text, snapshot, offsets[0]), tokenAt(text, snapshot, offsets[1])]

  test "resolves a local used as a qualified receiver":
    let text = """proc show(value: Item) =
  echo value.field
"""
    let snapshot = snapshotFor(text)
    let offsets = text.referenceOffsets("value")
    let references = resolveSameFileReferences(
      initWorkspace(), snapshot, offsets[1], includeDeclaration = true
    )
    check references.supported
    check references.tokens ==
      @[tokenAt(text, snapshot, offsets[0]), tokenAt(text, snapshot, offsets[1])]

  test "declines object field references":
    let text = """type Person = object
  name: string

proc show(person: Person) =
  discard person.name
"""
    let snapshot = snapshotFor(text)
    let references = resolveReferences(
      initWorkspace(), snapshot, text.rfind("name"), includeDeclaration = true
    )
    check not references.supported

  test "resolves nested block shadowing by binding identity":
    let text = """proc show(value: int) =
  block:
    let value = 1
    echo value
  echo value
"""
    let snapshot = snapshotFor(text)
    let offsets = text.referenceOffsets("value")
    let parentReferences = resolveSameFileReferences(
      initWorkspace(), snapshot, offsets[3], includeDeclaration = true
    )
    check parentReferences.supported
    check parentReferences.tokens ==
      @[tokenAt(text, snapshot, offsets[0]), tokenAt(text, snapshot, offsets[3])]
    let innerReferences = resolveSameFileReferences(
      initWorkspace(), snapshot, offsets[2], includeDeclaration = true
    )
    check innerReferences.supported
    check innerReferences.tokens ==
      @[tokenAt(text, snapshot, offsets[1]), tokenAt(text, snapshot, offsets[2])]

  test "supports unused locals and optional declarations":
    let text = """proc unused() =
  let value = 1
  discard
"""
    let snapshot = snapshotFor(text)
    let declaration = text.find("value")
    let withDeclaration = resolveSameFileReferences(
      initWorkspace(), snapshot, declaration, includeDeclaration = true
    )
    check withDeclaration.supported
    check withDeclaration.tokens == @[tokenAt(text, snapshot, declaration)]
    let withoutDeclaration = resolveSameFileReferences(
      initWorkspace(), snapshot, declaration, includeDeclaration = false
    )
    check withoutDeclaration.supported
    check withoutDeclaration.tokens.len == 0

  test "declines unsupported, non-local, and stale bindings":
    let nested = snapshotFor(
      """proc nested(value: int) =
  if value > 0:
    echo value
"""
    )
    check not resolveSameFileReferences(
      initWorkspace(), nested, nested.text.rfind("value"), true
    ).supported

    let moduleLevel = snapshotFor("let value = 1\necho value\n")
    check not resolveSameFileReferences(
      initWorkspace(), moduleLevel, moduleLevel.text.rfind("value"), true
    ).supported

    let ordered = snapshotFor(
      """proc ordered() =
  echo value
  let value = 1
"""
    )
    check not resolveSameFileReferences(
      initWorkspace(), ordered, ordered.text.find("value"), true
    ).supported

    let duplicate = snapshotFor(
      """proc duplicate() =
  let value = 1
  let value = 2
  echo value
"""
    )
    check not resolveSameFileReferences(
      initWorkspace(), duplicate, duplicate.text.rfind("value"), true
    ).supported

    var stale = snapshotFor(
      """proc stale(value: int) =
  echo value
"""
    )
    stale.text.add "\n"
    check not resolveSameFileReferences(
      initWorkspace(), stale, stale.text.rfind("value"), true
    ).supported

suite "native project references":
  test "resolves qualified aliases and plain from imports through the graph":
    let root = getTempDir() / ("onim-references-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-references-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let aliasPath = root / "alias_consumer.nim"
    let fromPath = root / "from_consumer.nim"
    writeFile(
      providerPath,
      """proc answer*() = discard
proc hidden() = discard
proc useAnswer() =
  answer()
""",
    )
    writeFile(
      aliasPath,
      """import provider as p
proc useAlias() =
  p.answer()
""",
    )
    writeFile(
      fromPath,
      """from provider import answer
proc useFrom() =
  answer()
""",
    )
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let providerId = workspace.fileIdForPath(providerPath)
    let aliasId = workspace.fileIdForPath(aliasPath)
    let fromId = workspace.fileIdForPath(fromPath)
    check providerId.valid and aliasId.valid and fromId.valid

    let privateSnapshot = workspace.snapshotForFile(providerId)
    let privateReferences = resolveReferences(
      workspace, privateSnapshot, privateSnapshot.text.find("hidden"), true
    )
    check not privateReferences.supported
    check privateReferences.matches.len == 0

    let aliasSnapshot = workspace.snapshotForFile(aliasId)
    let aliasReferences = resolveReferences(
      workspace, aliasSnapshot, aliasSnapshot.text.rfind("answer"), true
    )
    check aliasReferences.supported
    check aliasReferences.matches.len == 4
    var providerMatches = 0
    var aliasMatches = 0
    var fromMatches = 0
    for match in aliasReferences.matches:
      if match.fileId.value == providerId.value:
        inc providerMatches
      elif match.fileId.value == aliasId.value:
        inc aliasMatches
      elif match.fileId.value == fromId.value:
        inc fromMatches
    check providerMatches == 2
    check aliasMatches == 1
    check fromMatches == 1
    check aliasReferences.matches[0].fileId.value <=
      aliasReferences.matches[^1].fileId.value

    let fromSnapshot = workspace.snapshotForFile(fromId)
    let fromReferences = resolveReferences(
      workspace, fromSnapshot, fromSnapshot.text.rfind("answer"), false
    )
    check fromReferences.supported
    check fromReferences.matches.len == 3

    let overlayPath = root / "overlay_consumer.nim"
    let overlayId = workspace.openDocument(
      "file://" & overlayPath, overlayPath, "import provider\nprovider.answer()\n", 1
    )
    check workspace.dependencies(overlayId).len == 1
    check workspace.dependencies(overlayId)[0].value == providerId.value
    var hasOverlayDependent = false
    for dependent in workspace.dependents(providerId):
      if dependent.value == overlayId.value:
        hasOverlayDependent = true
    check hasOverlayDependent
    let overlaySnapshot = workspace.snapshotForFile(overlayId)
    let overlayReferences = resolveReferences(
      workspace, overlaySnapshot, overlaySnapshot.text.rfind("answer"), true
    )
    check overlayReferences.supported
    check overlayReferences.matches.len == 5

    let warmWorkspace = initWorkspace(root)
    warmWorkspace.indexWorkspace()
    check warmWorkspace.graphComplete
    let warmAliasId = warmWorkspace.fileIdForPath(aliasPath)
    let warmAliasSnapshot = warmWorkspace.snapshotForFile(warmAliasId)
    let warmReferences = resolveReferences(
      warmWorkspace, warmAliasSnapshot, warmAliasSnapshot.text.rfind("answer"), true
    )
    check warmReferences.supported
    check warmReferences.matches.len == aliasReferences.matches.len

    let changedAlias =
      "import provider as p\nproc useAlias() =\n  p.answer()\n  p.answer()\n"
    discard workspace.changeDocument("file://" & aliasPath, aliasPath, changedAlias, 2)
    let changedSnapshot = workspace.snapshotForFile(aliasId)
    let changedReferences = resolveReferences(
      workspace, changedSnapshot, changedSnapshot.text.rfind("answer"), true
    )
    check changedReferences.supported
    check changedReferences.matches.len == 6
    check changedSnapshot.contentGeneration.value !=
      aliasSnapshot.contentGeneration.value

    let uncertainPath = root / "uncertain_consumer.nim"
    writeFile(
      uncertainPath,
      """import provider
proc useUncertain() =
  provider.answer()
  answer()
  let answer = 1
""",
    )
    let uncertainId = workspace.openDocument(
      "file://" & uncertainPath, uncertainPath, readFile(uncertainPath), 1
    )
    check uncertainId.valid
    let uncertainSnapshot = workspace.snapshotForFile(uncertainId)
    let qualifiedAnswer =
      uncertainSnapshot.text.find("provider.answer") + "provider.".len
    let uncertainReferences =
      resolveReferences(workspace, uncertainSnapshot, qualifiedAnswer, true)
    check not uncertainReferences.supported
    check uncertainReferences.matches.len == 0
    removeFile(uncertainPath)

    let coldWorkspace = initWorkspace(root)
    let coldOverlayPath = root / "cold_consumer.nim"
    let coldOverlayId = coldWorkspace.openDocument(
      "file://" & coldOverlayPath,
      coldOverlayPath,
      "import provider\nprovider.answer()\n",
      1,
    )
    coldWorkspace.indexWorkspace()
    check coldWorkspace.graphComplete
    let coldProviderId = coldWorkspace.fileIdForPath(providerPath)
    var coldDependent = false
    for dependent in coldWorkspace.dependents(coldProviderId):
      if dependent.value == coldOverlayId.value:
        coldDependent = true
    check coldDependent
    let coldSnapshot = coldWorkspace.snapshotForFile(coldOverlayId)
    let coldReferences = resolveReferences(
      coldWorkspace, coldSnapshot, coldSnapshot.text.rfind("answer"), true
    )
    check coldReferences.supported
    check coldReferences.matches.len == 5
