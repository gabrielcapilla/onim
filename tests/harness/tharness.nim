import std/json
import std/os except FileId
import std/[strutils, streams, tables, unittest]

import harness/fixture
import harness/editor
import harness/render
import harness/source
import onim/features/completion_models
import onim/features/definition_models
import onim/features/hover
import onim/features/organize_edits
import onim/features/references
import onim/features/organize
import onim/semantic/native_diagnostics
import onim/protocol/diagnostics
import onim/protocol/document_changes
import onim/session/ids
import onim/session/workspace
import onim/protocol/positions
import onim/protocol/transport
import onim/protocol/uris
import onim/protocol/semantic_key
import onim/protocol/pending_cancellation
import onim/protocol/pending_code_actions
import onim/semantic/worker

suite "fixture parser harness":
  test "parses a default file and a cursor":
    let fixture = parseFixture("proc main() =\n  let valor = 1<|>0\n")
    check fixture.files.len == 1
    check fixture.files.hasKey("main.nim")
    check fixture.files["main.nim"] == "proc main() =\n  let valor = 10\n"
    check fixture.cursors.len == 1
    check fixture.cursors[0].file == "main.nim"
    check fixture.cursors[0].line == 1
    check fixture.cursors[0].character == 15
    check fixture.cursors[0].byteOffset == fixture.files["main.nim"].find("10") + 1

  test "parses multiple files and resets file-local positions":
    let fixture = parseFixture(
      """//- /provider.nim
proc answer*(): int = 42

//- /consumer.nim
import provider
echo ans<|>wer()
"""
    )
    check fixture.files.len == 2
    check fixture.files.hasKey("/provider.nim")
    check fixture.files.hasKey("/consumer.nim")
    check fixture.cursors.len == 1
    check fixture.cursors[0].file == "/consumer.nim"
    check fixture.cursors[0].line == 1
    check fixture.cursors[0].character == 8

  test "uses UTF-16 units and keeps byte offsets":
    let fixture = parseFixture("let emoji = \"😀\"<|>\n")
    check fixture.files["main.nim"] == "let emoji = \"😀\"\n"
    check fixture.cursors[0].character == 16
    check fixture.cursors[0].byteOffset == "let emoji = \"😀\"".len
    let source = fixture.files["main.nim"]
    let position =
      positionAt(initPositionIndex(source), source, fixture.cursors[0].byteOffset)
    check position["line"].getInt == fixture.cursors[0].line
    check position["character"].getInt == fixture.cursors[0].character

  test "preserves CRLF source text":
    let fixture = parseFixture("let value = 1<|>\r\n")
    check fixture.files["main.nim"] == "let value = 1\r\n"
    check fixture.cursors[0].character == 13

  test "rejects duplicate files":
    expect ValueError:
      discard parseFixture(
        """//- /same.nim
discard 1
//- /same.nim
discard 2
"""
      )

  test "records selection ranges without changing the source":
    let fixture = parseFixture("echo <sel>value<|></sel>\n")
    check fixture.files["main.nim"] == "echo value\n"
    check fixture.cursors.len == 1
    check fixture.ranges.len == 1
    check fixture.ranges[0].startLine == 0
    check fixture.ranges[0].startCharacter == 5
    check fixture.ranges[0].startByteOffset == 5
    check fixture.ranges[0].endCharacter == 10
    check fixture.ranges[0].endByteOffset == 10

  test "rejects unclosed and nested selections":
    expect ValueError:
      discard parseFixture("echo <sel>value\n")
    expect ValueError:
      discard parseFixture("echo <sel>a<sel>b</sel></sel>\n")

  test "tracks selections across lines and rejects section crossings":
    let fixture = parseFixture("echo <sel>first\nsecond</sel>\n")
    check fixture.files["main.nim"] == "echo first\nsecond\n"
    check fixture.ranges[0].startLine == 0
    check fixture.ranges[0].startCharacter == 5
    check fixture.ranges[0].endLine == 1
    check fixture.ranges[0].endCharacter == 6
    check fixture.ranges[0].startByteOffset == 5
    check fixture.ranges[0].endByteOffset == 17
    expect ValueError:
      discard parseFixture("<sel>one\n//- other.nim\ntwo</sel>\n")

  test "renders feature results canonically":
    let completion = CompletionResult(
      state: completionAvailable,
      replaceStart: 3,
      replaceEnd: 6,
      items: @[
        CompletionItem(
          label: "writeLine",
          kind: completionMethod,
          detail: "File.writeLine",
          documentation: "writes\nvalues",
          filterText: "writeLine",
          sortText: "0001",
          recovered: false,
          autoImportModule: "std/syncio",
        )
      ],
    )
    check renderCompletion(completion) ==
      "state=completionAvailable range=3:6\n" &
      "item label=writeLine kind=completionMethod detail=File.writeLine " &
      "documentation=writes\\nvalues filter=writeLine sort=0001 recovered=false " &
      "autoImport=std/syncio"

    let hover = HoverInfo(
      state: hoverAvailable,
      name: "writeLine",
      module: "std/syncio",
      kind: "proc",
      signature: "proc writeLine()",
      documentation: "writes\nvalues",
      rangeStartOffset: 2,
      rangeEndOffset: 11,
      declarationLine: 4,
      declarationText: "proc writeLine()",
    )
    check renderHover(hover).contains("documentation=writes\\nvalues")

    check renderDefinition(
      DefinitionResolution(
        kind: definitionResolved,
        target: DefinitionTarget(
          kind: targetDeclaration,
          fileId: FileId(2),
          snapshotId: SnapshotId(3),
          contentGeneration: ContentGeneration(4),
          nameToken: 5,
        ),
      )
    ) ==
      "state=definitionResolved target=targetDeclaration file=2 snapshot=3 " &
      "generation=4 token=5"
    check renderReferences(
      ReferencesResult(
        supported: true,
        target: DefinitionTarget(
          kind: targetDeclaration,
          fileId: FileId(2),
          snapshotId: SnapshotId(3),
          contentGeneration: ContentGeneration(4),
          nameToken: 5,
        ),
        matches: @[
          ReferenceMatch(
            fileId: FileId(7), contentGeneration: ContentGeneration(8), tokenIndex: 9
          )
        ],
      )
    ) ==
      "supported=true target=state=definitionResolved target=targetDeclaration file=2 " &
      "snapshot=3 generation=4 token=5\nmatch file=7 generation=8 token=9"
    check renderDiagnostics(
      @[
        NativeDiagnostic(
          kind: nativeTypo,
          startOffset: 1,
          endOffset: 4,
          name: "ehco",
          suggestion: "echo",
        )
      ]
    ) == "kind=nativeTypo range=1:4 name=ehco module= suggestion=echo"
    check renderEdits(
      @[ImportEdit(startOffset: 0, endOffset: 0, newText: "import std/os\n")]
    ) == "range=0:0 text=import std/os\\n"

  test "opens fixture files through the workspace adapter":
    let root = getTempDir() / ("onim-fixture-workspace-" & $getCurrentProcessId())
    let fixture = parseFixture(
      """//- provider.nim
proc answer*(): int = 42
//- main.nim
import provider
echo ans<|>wer()
"""
    )
    let workspace = initWorkspace(root)
    let ids = workspace.openFixtureDocuments(fixture, root)
    check ids.len == 2
    let mainPath = root / "main.nim"
    let snapshot = workspace.snapshotForDocument(fileUri(mainPath), mainPath)
    check snapshot.valid
    check snapshot.index != nil
    check snapshot.index.parsed.imports.len == 1
    let providerId = workspace.fileIdForPath(root / "provider.nim")
    let consumerId = workspace.fileIdForPath(root / "main.nim")
    check providerId.valid
    check consumerId.valid
    let dependencies = workspace.dependencies(consumerId)
    let dependents = workspace.dependents(providerId)
    check dependencies.len == 1
    check dependencies[0].value == providerId.value
    check dependents.len == 1
    check dependents[0].value == consumerId.value

  test "frames JSON-RPC messages through the production codec":
    let body = $(%*{"jsonrpc": "2.0", "method": "initialized"})
    let frame = frameMessage(body)
    check frame == "Content-Length: " & $body.len & "\r\n\r\n" & body
    let input = newStringStream(frame)
    check readMessageText(input) == body
    let output = newStringStream()
    sendMessage(output, %*{"jsonrpc": "2.0", "method": "initialized"})
    check output.data == frame

  test "preserves plus signs and spaces in file URIs":
    let path = "/tmp/project+zed/space file.nim"
    check uriToPath("file:///tmp/project+zed/space%20file.nim") == path
    check uriToPath("file:///tmp/project%2Bzed/space%20file.nim") == path
    check uriToPath(fileUri(path)) == path

  test "models document versions and rejects stale semantic generations":
    let root = getTempDir() / ("onim-editor-state-" & $getCurrentProcessId())
    let path = root / "main.nim"
    let uri = fileUri(path)
    let editor = initEditorState(root)
    check editor.openDocument(uri, path, "let value = 1\n", 1)
    let first = editor.capture(uri, path)
    check editor.isCurrent(first)

    check editor.applyChange(
      %*{
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": "let value = 2\n"}],
      }
    )
    check not editor.isCurrent(first)
    let second = editor.capture(uri, path)
    check editor.isCurrent(second)

    check not editor.applyChange(
      %*{
        "textDocument": {"uri": uri, "version": 1},
        "contentChanges": [{"text": "let value = 0\n"}],
      }
    )
    check editor.isCurrent(second)

    check editor.applyChange(
      %*{
        "textDocument": {"uri": uri, "version": 3},
        "contentChanges": [
          {
            "range": {
              "start": {"line": 0, "character": 12}, "end": {"line": 0, "character": 13}
            },
            "text": "3",
          }
        ],
      }
    )
    check editor.snapshot(uri, path).text == "let value = 3\n"

  test "shares production document transitions and preserves rejected state":
    let root = getTempDir() / ("onim-document-transitions-" & $getCurrentProcessId())
    let path = root / "main.nim"
    let uri = fileUri(path)
    let workspace = initWorkspace(root)
    let opened = applyDidOpen(
      workspace,
      %*{"textDocument": {"uri": uri, "version": 1, "text": "let value = 1\n"}},
    )
    check opened.accepted
    check opened.current.text == "let value = 1\n"

    let rejected = applyDidChange(
      workspace,
      %*{
        "textDocument": {"uri": uri, "version": 1},
        "contentChanges": [{"text": "let value = 0\n"}],
      },
    )
    check not rejected.accepted
    check rejected.before.text == opened.current.text
    check workspace.snapshotForDocument(uri, path).text == opened.current.text

    let changed = applyDidChange(
      workspace,
      %*{
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [
          {
            "range": {
              "start": {"line": 0, "character": 12}, "end": {"line": 0, "character": 13}
            },
            "text": "2",
          }
        ],
      },
    )
    check changed.accepted
    check changed.contentChanged
    check changed.current.text == "let value = 2\n"

  test "cancellation returns state effects without writing transport output":
    let key = SemanticKey(
      fileId: FileId(1),
      workKind: semanticOrganize,
      contentGeneration: ContentGeneration(1),
      dependencyGeneration: DependencyGeneration(1),
      configGeneration: ConfigGeneration(1),
      surfaceGeneration: SurfaceGeneration(1),
      useStdPrefix: true,
    )
    var pending = @[
      PendingCodeAction(id: %*1, semantic: key, uri: "file:///one.nim"),
      PendingCodeAction(id: %*2, semantic: key, uri: "file:///one.nim"),
    ]
    var queued = @[
      SemanticRequest(
        kind: semanticOrganize,
        fileId: FileId(1),
        contentGeneration: ContentGeneration(1),
        dependencyGeneration: DependencyGeneration(1),
        configGeneration: ConfigGeneration(1),
        surfaceGeneration: SurfaceGeneration(1),
        useStdPrefix: true,
      )
    ]
    var active = key

    let first = cancelPendingCodeAction(pending, queued, active, %*1)
    check first.found
    check not first.stopWorker
    check pending.len == 1
    check queued.len == 1

    let second = cancelPendingCodeAction(pending, queued, active, %*2)
    check second.found
    check second.stopWorker
    check not active.fileId.valid
    check queued.len == 0

    let unknown = cancelPendingCodeAction(pending, queued, active, %*99)
    check not unknown.found
    check not unknown.stopWorker

    pending.add PendingCodeAction(id: %*3, semantic: key, uri: "file:///one.nim")
    let responses = finishPendingCodeActionsForUri(pending, "file:///one.nim")
    check pending.len == 0
    check responses.len == 1
    check responses[0].id.getInt == 3
    check responses[0].result.kind == JArray

  test "rejects semantic results captured before a document change":
    let root = getTempDir() / ("onim-semantic-generation-" & $getCurrentProcessId())
    let path = root / "main.nim"
    let uri = fileUri(path)
    let editor = initEditorState(root)
    check editor.openDocument(uri, path, "let value = 1\n", 1)
    let options = OrganizeOptions(useStdPrefix: true)
    let stale = semanticKey(editor.snapshot(uri, path), options)
    check editor.applyChange(
      %*{
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": "let value = 2\n"}],
      }
    )
    let current = semanticKey(editor.snapshot(uri, path), options)
    check not sameSemanticKey(current, stale)
    check not sameSemanticGeneration(current, stale)

  test "encodes diagnostic versions and UTF-16 ranges without stdout":
    let payload = diagnosticsPayload(
      "file:///main.nim",
      "ehco 😀\n",
      @[
        NativeDiagnostic(
          kind: nativeTypo,
          startOffset: 0,
          endOffset: 4,
          name: "ehco",
          suggestion: "echo",
        )
      ],
      version = 4,
    )
    check payload["method"].getStr == "textDocument/publishDiagnostics"
    check payload["params"]["version"].getInt == 4
    check payload["params"]["diagnostics"].len == 1
    check payload["params"]["diagnostics"][0]["range"]["end"]["character"].getInt == 4
