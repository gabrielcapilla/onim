import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import onim/protocol/pending_cancellation
import onim/protocol/pending_workspace
import harness/stdio

suite "stdio LSP document state":
  test "filters deferred requests by changed document URI":
    var pending = @[
      PendingWorkspaceRequest(
        kind: pendingSignatureHelp,
        id: %*1,
        params: %*{"textDocument": {"uri": "file:///consumer.nim"}},
      ),
      PendingWorkspaceRequest(
        kind: pendingHover,
        id: %*2,
        params: %*{"textDocument": {"uri": "file:///consumer.nim"}},
      ),
      PendingWorkspaceRequest(
        kind: pendingDocumentLink,
        id: %*3,
        params: %*{"textDocument": {"uri": "file:///consumer.nim"}},
      ),
      PendingWorkspaceRequest(
        kind: pendingCompletion,
        id: %*7,
        params: %*{"textDocument": {"uri": "file:///consumer.nim"}},
      ),
      PendingWorkspaceRequest(
        kind: pendingIncomingCalls,
        id: %*4,
        params: %*{"item": {"uri": "file:///consumer.nim"}},
      ),
      PendingWorkspaceRequest(
        kind: pendingOutgoingCalls,
        id: %*5,
        params: %*{"item": {"uri": "file:///other.nim"}},
      ),
      PendingWorkspaceRequest(
        kind: pendingWorkspaceSymbol, id: %*6, params: %*{"query": "answer"}
      ),
    ]
    let canceled = cancelPendingWorkspaceRequestsForUri(pending, "file:///consumer.nim")
    check canceled.len == 5
    check canceled[0].getInt == 1
    check canceled[1].getInt == 2
    check canceled[2].getInt == 3
    check canceled[3].getInt == 7
    check canceled[4].getInt == 4
    check pending.len == 2
    check pending[0].id.getInt == 5
    check pending[1].id.getInt == 6
    check cancelPendingWorkspaceRequestsForUri(pending, "file:///consumer.nim").len == 0

  test "cancels a pending workspace request":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-cancel-" & $getCurrentProcessId())
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "proc answer*() = discard\n")
    writeFile(consumerPath, "import provider\nprovider.answer()\n")
    for index in 0 ..< 256:
      writeFile(root / ("module" & $index & ".nim"), "proc value*() = discard\n")
    let consumerUri = "file://" & consumerPath.replace('\\', '/')
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process
      for path in walkDirRec(root):
        if fileExists(path):
          removeFile(path)
      removeDir(root)

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": "file://" & root.replace('\\', '/')},
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 9}
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 2}},
    )
    check readResponse(process.outputStream, 1) != nil
    let canceled = readResponse(process.outputStream, 2)
    check canceled != nil
    check canceled["error"]["code"].getInt == -32800

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "rejects invalid full changes and preserves save versions":
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let filePath = getTempDir() / ("onim-sync-" & $getCurrentProcessId() & ".nim")
    let uri = "file://" & filePath.replace('\\', '/')
    let initial = "proc main() = discard\n"
    let changed = "proc main() =\n  for k, v in walkDir(\"/tmp\"): discard k\n"
    let saved = "proc main() = discard\n"
    writeFile(filePath, initial)
    defer:
      if fileExists(filePath):
        removeFile(filePath)
    let process = startProcess(root / "onim", args = ["--stdio"], workingDir = root)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": "file://" & root.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 1) != nil
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {"textDocument": {"uri": uri, "version": 1, "text": initial}},
      },
    )
    discard readDiagnostics(process.outputStream, uri)

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 2},
          "contentChanges": [{"text": changed}, {"text": initial}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 2},
          "contentChanges": [{"text": changed}],
        },
      },
    )
    let changedDiagnostics = readDiagnostics(process.outputStream, uri)
    check changedDiagnostics["params"]["diagnostics"].len == 1
    check changedDiagnostics["params"]["diagnostics"][0]["message"].getStr.contains(
      "std/os"
    )

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 3},
          "contentChanges":
            [{"range": {"start": {"line": 0, "character": 0}}, "text": saved}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri}, "context": {"only": ["source.organizeImports"]}
        },
      },
    )
    let retainedChange = readResponse(process.outputStream, 2)
    check retainedChange["result"].len == 1
    check retainedChange["result"][0]["edit"]["changes"][uri][0]["newText"].getStr.contains(
      "std/os"
    )

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didSave",
        "params": {"textDocument": {"uri": uri}, "text": saved},
      },
    )
    let savedDiagnostics = readDiagnostics(process.outputStream, uri)
    check savedDiagnostics["params"]["diagnostics"].len == 0
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 2},
          "contentChanges": [{"text": changed}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri}, "context": {"only": ["source.organizeImports"]}
        },
      },
    )
    check readResponse(process.outputStream, 3)["result"].len == 0

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 4, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 4)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "applies sequential incremental edits with UTF-16 ranges":
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let filePath =
      getTempDir() / ("onim-incremental-" & $getCurrentProcessId() & ".nim")
    let uri = "file://" & filePath.replace('\\', '/')
    let initial =
      "proc main() =\n" & "  let smile = \"😀\"\n" & "  let value = 1\n" &
      "  discard value\n"
    writeFile(filePath, initial)
    defer:
      if fileExists(filePath):
        removeFile(filePath)
    let process = startProcess(root / "onim", args = ["--stdio"], workingDir = root)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": "file://" & root.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 1) != nil
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {"textDocument": {"uri": uri, "version": 1, "text": initial}},
      },
    )
    discard readDiagnostics(process.outputStream, uri)

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 2},
          "contentChanges": [
            {
              "range": {
                "start": {"line": 1, "character": 15},
                "end": {"line": 1, "character": 17},
              },
              "text": "🙂",
            },
            {
              "range": {
                "start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 0}
              },
              "text": "  let extra = 2\n",
            },
          ],
        },
      },
    )
    discard readDiagnostics(process.outputStream, uri)

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/hover",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 10}},
      },
    )
    let hover = readResponse(process.outputStream, 2)
    check hover != nil
    check hover["result"]["contents"]["value"].getStr.contains("let value: uint8")

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0
