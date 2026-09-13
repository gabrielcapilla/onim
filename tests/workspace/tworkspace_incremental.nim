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
  test "incrementally reindexes same-line references":
    let oldSource = "let value = 1\necho value\n"
    let newSource = "let value = 1\necho other\n"
    let oldIndex = indexSource(oldSource)
    let incremental = tryIndexSourceIncremental(oldSource, oldIndex, newSource)
    let rebuilt = indexSource(newSource)
    check incremental != nil
    check incremental.contentHash == rebuilt.contentHash
    check incremental.byteLength == rebuilt.byteLength
    check incremental.tokenCount == rebuilt.tokenCount
    check incremental.parsed.tokens == rebuilt.parsed.tokens
    check incremental.parsed.imports == rebuilt.parsed.imports
    check incremental.symbols == rebuilt.symbols
    check incremental.scopes == rebuilt.scopes
    check incremental.occurrences == rebuilt.occurrences
    check incremental.imports == rebuilt.imports
    check incremental.exports == rebuilt.exports
    check incremental.includes == rebuilt.includes
    check incremental.scopes.validateScopes(
      incremental.parsed.tokens, incremental.symbols, incremental.byteLength
    )
    check incremental.occurrences.validateOccurrences(incremental.parsed.tokens)

    check tryIndexSourceIncremental(oldSource, oldIndex, "let value = 1\necho other!\n") ==
      nil
    check tryIndexSourceIncremental(
      oldSource, oldIndex, "let value = 1\necho value\n# edit\n"
    ) == nil
    check tryIndexSourceIncremental(
      "import std/os\necho value\n",
      indexSource("import std/os\necho value\n"),
      "import std/db\necho value\n",
    ) == nil

    let workspace = initWorkspace()
    let fileId =
      workspace.openDocument("file:///incremental.nim", "incremental.nim", oldSource, 1)
    check workspace.changeDocument(
      "file:///incremental.nim", "incremental.nim", newSource, 2
    )
    check workspace.snapshotForFile(fileId).index.occurrences == rebuilt.occurrences

    let repeatedOld = "let value = 1\necho value\necho value\n"
    let repeatedNew = "let value = 1\necho other\necho value\n"
    let repeated =
      tryIndexSourceIncremental(repeatedOld, indexSource(repeatedOld), repeatedNew)
    check repeated != nil
    check repeated.occurrences == indexSource(repeatedNew).occurrences
    check tryIndexSourceIncremental(
      "include module\necho value\n",
      indexSource("include module\necho value\n"),
      "include changed\necho value\n",
    ) == nil
    check tryIndexSourceIncremental(
      "echo \"value\"\n", indexSource("echo \"value\"\n"), "echo \"other\"\n"
    ) == nil

  test "incremental successors keep predecessor indexes immutable":
    var source = "let value = 1\n"
    for _ in 0 ..< 130:
      source.add "echo value\n"
    let originalSource = source
    let originalIndex = indexSource(source)
    var current = originalIndex
    let edits =
      [(line: 1, name: "other"), (line: 64, name: "third"), (line: 127, name: "final")]
    for edit in edits:
      let previousSource = source
      let previousIndex = current
      source = replaceLine(source, edit.line, edit.name)
      current = tryIndexSourceIncremental(previousSource, previousIndex, source)
      if current == nil:
        raise
          newException(AssertionDefect, "incremental edit failed at line " & $edit.line)
      let rebuilt = indexSource(source)
      check current.parsed.tokens == rebuilt.parsed.tokens
      check current.symbols == rebuilt.symbols
      check current.scopes == rebuilt.scopes
      check current.occurrences == rebuilt.occurrences
      let previousRebuilt = indexSource(previousSource)
      check previousIndex.parsed.tokens == previousRebuilt.parsed.tokens
      check previousIndex.occurrences == previousRebuilt.occurrences

    let originalRebuilt = indexSource(originalSource)
    check originalIndex.parsed.tokens == originalRebuilt.parsed.tokens
    check originalIndex.occurrences == originalRebuilt.occurrences
