import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio

suite "stdio LSP protocol validation":
  test "validates JSON-RPC envelopes and gates shutdown":
    let root = currentSourcePath().parentDir.parentDir.parentDir
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

    sendRaw(process.inputStream, "{not-json")
    let parseError = readMessage(process.outputStream)
    check parseError["id"].kind == JNull
    check parseError["error"]["code"].getInt == -32700

    sendRaw(process.inputStream, "{\"jsonrpc\":\"2.0\",\"method\":42}")
    let invalidRequest = readMessage(process.outputStream)
    check invalidRequest["id"].kind == JNull
    check invalidRequest["error"]["code"].getInt == -32600

    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "shutdown"})
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": "unknown", "method": "probe"}
    )
    let unknown = readMessage(process.outputStream)
    check unknown["id"].kind == JString
    check unknown["id"].getStr == "unknown"
    check unknown["error"]["code"].getInt == -32601

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 2)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "id": 3, "method": "probe"})
    let afterShutdown = readResponse(process.outputStream, 3)
    check afterShutdown["error"]["code"].getInt == -32600
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "id": 4, "method": "exit"})
    check readResponse(process.outputStream, 4)["error"]["code"].getInt == -32600
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "rejects malformed method params without mutating the session":
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let filePath = getTempDir() / ("onim-params-" & $getCurrentProcessId() & ".nim")
    let uri = "file://" & filePath.replace('\\', '/')
    let source = "proc initial() = discard\n"
    let changed = "proc changed() = discard\n"
    writeFile(filePath, source)
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
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 10,
        "method": "textDocument/semanticTokens/range",
        "params": {"textDocument": {"uri": uri}},
      },
    )
    let missingSemanticRange = readResponse(process.outputStream, 10)
    check missingSemanticRange != nil
    check missingSemanticRange["error"]["code"].getInt == -32602

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 11,
        "method": "textDocument/semanticTokens/range",
        "params": {
          "textDocument": {"uri": uri},
          "range": {"start": [], "end": {"line": 0, "character": 0}},
        },
      },
    )
    let malformedSemanticRange = readResponse(process.outputStream, 11)
    check malformedSemanticRange != nil
    check malformedSemanticRange["error"]["code"].getInt == -32602

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {"textDocument": {"uri": uri, "version": "bad", "text": source}},
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didClose",
        "params": {"textDocument": []},
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didSave",
        "params": {"textDocument": {"uri": uri}, "text": 1},
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "workspace/didChangeWatchedFiles",
        "params": {"changes": [{"uri": uri, "type": 3}, {"uri": 4, "type": 3}]},
      },
    )
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 2, "method": "textDocument/codeAction", "params": []},
    )
    let invalidAction = readResponse(process.outputStream, 2)
    check invalidAction != nil
    check invalidAction["error"]["code"].getInt == -32602

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "textDocument/definition",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": "bad", "character": 0}},
      },
    )
    let invalidDefinition = readResponse(process.outputStream, 3)
    check invalidDefinition != nil
    check invalidDefinition["error"]["code"].getInt == -32602

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "id": 4,
        "params": {"textDocument": {"uri": uri, "version": 1, "text": source}},
      },
    )
    let invalidForm = readResponse(process.outputStream, 4)
    check invalidForm != nil
    check invalidForm["error"]["code"].getInt == -32600

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {"textDocument": {"uri": uri, "version": 1, "text": source}},
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didClose",
        "params": {"textDocument": []},
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
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 7,
        "method": "textDocument/documentSymbol",
        "params": {"textDocument": {"uri": uri}},
      },
    )
    let symbols = readResponse(process.outputStream, 7)
    check symbols != nil
    check symbols["result"].len == 1
    check symbols["result"][0]["name"].getStr == "changed"

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0", "id": 5, "method": "shutdown", "params": {"unexpected": true}
      },
    )
    check readResponse(process.outputStream, 5)["error"]["code"].getInt == -32602
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "method": "exit", "params": {"unexpected": true}},
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 8,
        "method": "textDocument/documentSymbol",
        "params": {"textDocument": {"uri": uri}},
      },
    )
    check readResponse(process.outputStream, 8) != nil
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 6, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 6)["result"].kind == JNull
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "method": "exit", "params": {"unexpected": true}},
    )
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "id": 9, "method": "probe"})
    check readResponse(process.outputStream, 9)["error"]["code"].getInt == -32600
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0
