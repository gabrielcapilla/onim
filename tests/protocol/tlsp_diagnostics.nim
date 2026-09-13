import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio

suite "stdio LSP diagnostics":
  test "publishes native project-import diagnostics on first open":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-project-diagnostic-" & $getCurrentProcessId())
    if dirExists(root):
      for path in walkDirRec(root):
        if fileExists(path):
          removeFile(path)
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let consumerUri = "file://" & consumerPath.replace('\\', '/')
    writeFile(providerPath, "proc answer*() = discard\n")
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process
      if fileExists(providerPath):
        removeFile(providerPath)
      if fileExists(consumerPath):
        removeFile(consumerPath)
      if dirExists(root):
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
    check readResponse(process.outputStream, 1) != nil
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": consumerUri,
            "languageId": "nim",
            "version": 1,
            "text": "proc main() =\n  discard provider.answer()\n",
          }
        },
      },
    )
    let missing = readMessage(process.outputStream)
    check missing != nil
    check missing["method"].getStr == "textDocument/publishDiagnostics"
    check missing["params"]["version"].getInt == 1
    check missing["params"]["diagnostics"].len == 1
    check missing["params"]["diagnostics"][0]["message"].getStr.contains(
      "project import: provider"
    )

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 4,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": consumerUri},
          "context": {"only": ["source.organizeImports"]},
        },
      },
    )
    let projectAction = readResponse(process.outputStream, 4)
    check projectAction != nil
    check projectAction["result"].len == 1
    check projectAction["result"][0]["edit"]["changes"][consumerUri][0]["newText"].getStr.contains(
      "import provider"
    )

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": consumerUri, "version": 2},
          "contentChanges":
            [{"text": "import provider\nproc main() =\n  discard provider.answer()\n"}],
        },
      },
    )
    let resolved = readMessage(process.outputStream)
    check resolved != nil
    check resolved["params"]["version"].getInt == 2
    check resolved["params"]["diagnostics"].len == 0

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 2)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "publishes typo diagnostics and returns a validated quick fix":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let uri = "file:///tmp/onim-typo.nim"
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 301,
        "method": "initialize",
        "params": {"rootUri": "file://" & projectRoot.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 301) != nil
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": uri,
            "languageId": "nim",
            "version": 1,
            "text": "proc main() =\n  ehco \"hi\"\n",
          }
        },
      },
    )
    let diagnostics = readDiagnostics(process.outputStream, uri)
    check diagnostics != nil
    var typoDiagnostic: JsonNode
    for diagnostic in diagnostics["params"]["diagnostics"].items:
      if diagnostic.hasKey("code") and diagnostic["code"].getStr == "onim.typo":
        typoDiagnostic = diagnostic
    check typoDiagnostic != nil
    check typoDiagnostic["message"].getStr.contains("did you mean echo")
    check typoDiagnostic["data"]["replacement"].getStr == "echo"

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 302,
        "method": "textDocument/hover",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 4}},
      },
    )
    let hover = readResponse(process.outputStream, 302)
    check hover != nil
    check hover["result"]["contents"]["value"].getStr.contains("Did you mean `echo`")

    let mainCallUri = "file:///tmp/onim-main-call.nim"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": mainCallUri,
            "languageId": "nim",
            "version": 1,
            "text":
              "import std/strformat\n\nlet number = 190_000\nlet word: string = \"World\"\n\nproc main() =\n  stdout.writeLine fmt\"Number: {number}\"\n\nmain()\n",
          }
        },
      },
    )
    let mainDiagnostics = readDiagnostics(process.outputStream, mainCallUri)
    check mainDiagnostics != nil
    for diagnostic in mainDiagnostics["params"]["diagnostics"].items:
      check not diagnostic["message"].getStr.contains("unknown identifier: main")

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 303,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri},
          "context": {"only": ["quickfix"], "diagnostics": [typoDiagnostic]},
        },
      },
    )
    let actions = readResponse(process.outputStream, 303)
    check actions != nil
    check actions["result"].len == 1
    check actions["result"][0]["kind"].getStr == "quickfix"
    check actions["result"][0]["edit"]["changes"][uri][0]["newText"].getStr == "echo"

    let autoImportUri = "file:///tmp/onim-auto-import.nim"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": autoImportUri,
            "languageId": "nim",
            "version": 1,
            "text": "proc main() =\n  par\n",
          }
        },
      },
    )
    discard readDiagnostics(process.outputStream, autoImportUri)
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 305,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": autoImportUri},
          "position": {"line": 1, "character": 5},
        },
      },
    )
    let autoImport = readResponse(process.outputStream, 305)
    check autoImport != nil
    var parseJsonItem: JsonNode
    for item in autoImport["result"]["items"].items:
      if item["label"].getStr == "parseJson":
        parseJsonItem = item
    check parseJsonItem != nil
    check parseJsonItem["additionalTextEdits"].len == 1
    check parseJsonItem["additionalTextEdits"][0]["newText"].getStr.contains(
      "import std/json"
    )

    let memberCompletionUri = "file:///tmp/onim-member-completion.nim"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": memberCompletionUri,
            "languageId": "nim",
            "version": 1,
            "text": "proc main() =\n  stdout.writeLine\n",
          }
        },
      },
    )
    discard readDiagnostics(process.outputStream, memberCompletionUri)
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 306,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": memberCompletionUri},
          "position": {"line": 1, "character": 18},
        },
      },
    )
    let memberCompletion = readResponse(process.outputStream, 306)
    check memberCompletion != nil
    var writeLineItem: JsonNode
    for item in memberCompletion["result"]["items"].items:
      if item["label"].getStr == "writeLine":
        writeLineItem = item
    check writeLineItem != nil
    check writeLineItem.hasKey("detail")
    check not writeLineItem["detail"].getStr.startsWith("writeLine")
    check writeLineItem["detail"].getStr.startsWith("[Ty]")
    check writeLineItem["documentation"]["value"].getStr.contains("Writes the values")
    check not writeLineItem["documentation"]["value"].getStr.startsWith(
      "proc writeLine"
    )

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 307,
        "method": "textDocument/hover",
        "params": {
          "textDocument": {"uri": memberCompletionUri},
          "position": {"line": 1, "character": 13},
        },
      },
    )
    let memberHover = readResponse(process.outputStream, 307)
    check memberHover != nil
    check memberHover["result"]["contents"]["value"].getStr.contains("writeLine")
    check memberHover["result"]["contents"]["value"].getStr.contains(
      "Writes the values"
    )

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 304, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 304)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0
