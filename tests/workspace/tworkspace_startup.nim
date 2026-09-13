import std/[strutils, unittest]
import std/os except FileId

import onim/index/cache
import onim/index/occurrences
import onim/index/scopes
import onim/index/scope_validation
import onim/index/source_index
import onim/index/surfaces
import onim/index/surface_resolution
import onim/session/ids
import onim/session/paths
import onim/session/workspace
import onim/session/workspace_models
import onim/index/type_kinds
import onim/index/type_queries
import onim/index/type_local_resolution
import onim/syntax/parser
import onim/syntax/tokens
import harness/workspace_fs
import workspace/workspace_support

suite "workspace index":
  test "narrows document bootstrap to the nearest project root":
    let root = getTempDir() / ("onim-root-selection-" & $getCurrentProcessId())
    cleanTree(root)
    defer:
      cleanTree(root)
    let project = root / "project"
    let sourceRoot = project / "src"
    let mainPath = sourceRoot / "main.nim"
    let unrelatedPath = root / "unrelated" / "other.nim"
    createDir(sourceRoot)
    createDir(splitFile(unrelatedPath).dir)
    writeFile(project / "nim.cfg", "")
    writeFile(mainPath, "discard\n")
    writeFile(sourceRoot / "module.nim", "discard\n")
    writeFile(unrelatedPath, "discard\n")

    let workspace = initWorkspace()
    check broadWorkspaceRoot(getHomeDir())
    check broadWorkspaceRoot("/")
    check not broadWorkspaceRoot(root)
    check workspace.root.len == 0
    check workspace.prepareWorkspaceForDocument(mainPath)
    check workspace.root == canonicalPath(project)

    workspace.indexWorkspace()
    check workspace.fileIdForPath(mainPath).valid
    check not workspace.fileIdForPath(unrelatedPath).valid

  test "keeps an unmarked document local without recursive bootstrap":
    let root = getTempDir() / ("onim-root-selection-local-" & $getCurrentProcessId())
    cleanTree(root)
    defer:
      cleanTree(root)
    let path = root / "main.nim"
    createDir(root)
    writeFile(path, "discard\n")

    let workspace = initWorkspace()
    check not workspace.prepareWorkspaceForDocument(path)
    check workspace.root.len == 0
    check workspace.openDocument("file://" & path, path, "discard\n", 1).valid

  test "persists and reloads source indexes":
    let root = getTempDir() / ("onim-cache-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let filePath = root / "cached.nim"
    let source =
      "import std/os\nproc listFiles(dir: string) =\n  let widths: array[4, int] = default(array[4, int])\n  discard walkDir(dir)\n  discard widths\n"
    writeFile(filePath, source)

    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let firstWorkspace = initWorkspace(root)
    firstWorkspace.indexWorkspace()
    let firstId = firstWorkspace.fileIdForPath(filePath)
    let firstSnapshot = firstWorkspace.snapshotForFile(firstId)
    let path = cacheFilePath(root, filePath)
    let manifestPath = projectManifestPath(root)
    check fileExists(path)
    check fileExists(manifestPath)
    check firstWorkspace.manifest.root == absolutePath(root)
    check firstWorkspace.manifest.entries.len == 1
    check firstWorkspace.manifest.discoveryValid
    check firstWorkspace.manifest.directories.len > 0
    check firstWorkspace.manifest.entries[0].path == absolutePath(filePath)
    check firstSnapshot.index != nil
    check loadCachedSourceIndex(root, filePath, source) != nil
    check loadCachedSourceIndexFingerprint(
      root, filePath, contentFingerprint(source), source.len
    ) != nil
    check loadCachedSourceIndex(root, filePath, source & "# changed\n") == nil
    var invalidGraphEntry = firstWorkspace.manifest.entries[0]
    invalidGraphEntry.forwardOrdinals = @[1'u32]
    check not saveProjectManifest(root, @[invalidGraphEntry], graphValid = true)

    let secondWorkspace = initWorkspace(root)
    secondWorkspace.indexWorkspace()
    let secondSnapshot =
      secondWorkspace.snapshotForFile(secondWorkspace.fileIdForPath(filePath))
    check secondWorkspace.manifest.entries.len == 1
    check secondWorkspace.manifest.discoveryValid
    check secondWorkspace.manifest.directories.len ==
      firstWorkspace.manifest.directories.len
    check secondWorkspace.manifest.entries[0].sourceHash ==
      firstWorkspace.manifest.entries[0].sourceHash
    check secondSnapshot.index != nil
    check secondSnapshot.index.contentHash == firstSnapshot.index.contentHash
    check secondSnapshot.index.tokenCount == firstSnapshot.index.tokenCount
    check secondSnapshot.index.parsed.tokens == firstSnapshot.index.parsed.tokens
    check secondSnapshot.index.parsed.imports.len ==
      firstSnapshot.index.parsed.imports.len
    check secondSnapshot.index.symbols == firstSnapshot.index.symbols
    check secondSnapshot.index.scopes == firstSnapshot.index.scopes
    check secondSnapshot.index.scopes.validateScopes(
      secondSnapshot.index.parsed.tokens, secondSnapshot.index.symbols,
      secondSnapshot.index.byteLength,
    )
    check secondSnapshot.index.occurrences == firstSnapshot.index.occurrences
    check secondSnapshot.index.occurrences.validateOccurrences(
      secondSnapshot.index.parsed.tokens
    )
    var widthsToken = InvalidTypeToken
    for declaration in secondSnapshot.index.scopes.declarations:
      let token = secondSnapshot.index.parsed.tokens[int(declaration.nameToken)]
      if secondSnapshot.index.parsed.tokens.tokenTextEquals(token, "widths"):
        widthsToken = declaration.nameToken
    check widthsToken != InvalidTypeToken
    let widths = secondSnapshot.index.types.localTypeAt(
      secondSnapshot.index.parsed.tokens, secondSnapshot.index.scopes, widthsToken
    )
    check widths.kind == typeArray
    check secondSnapshot.index.types.records[int(uint32(widths.typeId)) - 1].extent ==
      4'u32
    check secondSnapshot.index.nativeIndexSafe()

    let cacheBytes = readFile(path)
    writeFile(path, cacheBytes & "trailing")
    check loadCachedSourceIndex(root, filePath, source) == nil
    writeFile(path, "corrupt")
    check loadCachedSourceIndex(root, filePath, source) == nil

    let manifestBytes = readFile(manifestPath)
    writeFile(manifestPath, manifestBytes & "trailing")
    check loadProjectManifest(root).entries.len == 0

  test "persists recovered import boundaries":
    let root = getTempDir() / ("onim-recovery-cache-project-" & $getCurrentProcessId())
    let cacheRoot = getTempDir() / ("onim-recovery-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let modulePath = root / "main.nim"
    let source = "import goodA\nimport pkg/[part,\nimport goodB\n"
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let index = indexSource(source)
    check index.syntax.importNodes.len == 3
    check index.imports == @["goodA", "goodB"]
    check saveCachedSourceIndex(root, modulePath, source, index)
    let loaded = loadCachedSourceIndex(root, modulePath, source)
    check loaded != nil
    check loaded.imports == index.imports
    check loaded.parsed.imports == index.parsed.imports
    check loaded.syntax.importNodes.len == index.syntax.importNodes.len
    check loaded.syntax.nodes[int(uint32(loaded.syntax.importNodes[1])) - 1].uncertainty ==
      index.syntax.nodes[int(uint32(index.syntax.importNodes[1])) - 1].uncertainty
    check loaded.syntax.importsMatch(loaded.parsed)
