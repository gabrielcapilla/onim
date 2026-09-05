import std/[json, os, osproc, streams, strutils, unittest]

proc sendMessage(input: Stream, message: JsonNode) =
  let body = $message
  input.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  input.flush

proc readMessage(output: Stream): JsonNode =
  var contentLength = -1
  var line = ""
  while output.readLine(line):
    if line.len == 0:
      break
    let separator = line.find(':')
    if separator >= 0 and line[0 ..< separator].toLowerAscii == "content-length":
      contentLength = parseInt(line[separator + 1 .. ^1].strip)
  if contentLength < 0:
    return nil
  parseJson(output.readStr(contentLength))

proc readResponse(output: Stream, id: int): JsonNode =
  while true:
    let message = readMessage(output)
    if message == nil:
      return
    if message.hasKey("id") and message["id"].kind == JInt and message["id"].getInt == id:
      return message

suite "stdio LSP":
  test "returns organize-imports workspace edit":
    let root = currentSourcePath().parentDir.parentDir
    let filePath = root / "tests" / "before" / "walkdir.nim"
    let uri = "file://" & filePath.replace('\\', '/')
    let process = startProcess(root / "onim", args = ["--stdio"], workingDir = root)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "rootUri": "file://" & root.replace('\\', '/'),
          "initializationOptions": {"useStdPrefix": true},
        },
      },
    )
    let initialized = readResponse(process.outputStream, 1)
    check initialized != nil
    check initialized["result"]["capabilities"]["codeActionProvider"] != nil
    check initialized["result"]["capabilities"]["definitionProvider"].getBool
    check initialized["result"]["capabilities"]["hoverProvider"].getBool
    check initialized["result"]["capabilities"]["referencesProvider"].getBool
    check initialized["result"]["capabilities"]["documentSymbolProvider"].getBool

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument":
            {"uri": uri, "languageId": "nim", "version": 1, "text": readFile(filePath)}
        },
      },
    )
    let openedDiagnostics = readMessage(process.outputStream)
    check openedDiagnostics != nil
    check openedDiagnostics["method"].getStr == "textDocument/publishDiagnostics"
    check openedDiagnostics["params"]["diagnostics"].len == 1
    check openedDiagnostics["params"]["diagnostics"][0]["message"].getStr.contains(
      "std/os"
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri},
          "range":
            {"start": {"line": 0, "character": 0}, "end": {"line": 4, "character": 0}},
          "context": {"only": ["source.organizeImports"]},
        },
      },
    )
    let actions = readResponse(process.outputStream, 2)
    check actions != nil
    check actions["result"].kind == JArray
    check actions["result"].len == 1
    check actions["result"][0]["edit"]["changes"][uri][0]["newText"].getStr.contains(
      "import std/os"
    )

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 4,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri},
          "range":
            {"start": {"line": 0, "character": 0}, "end": {"line": 4, "character": 0}},
          "context": {"only": ["source.organizeImports"]},
        },
      },
    )
    let cachedActions = readResponse(process.outputStream, 4)
    check cachedActions != nil
    check cachedActions["result"].len == 1
    check cachedActions["result"][0]["edit"]["changes"][uri][0]["newText"].getStr.contains(
      "import std/os"
    )

    let definitionUri = "file:///tmp/onim-definition.nim"
    let definitionText = "let smile = \"😀\"\nproc helper*() = discard\nhelper()\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": definitionUri,
            "languageId": "nim",
            "version": 1,
            "text": definitionText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 10,
        "method": "textDocument/documentSymbol",
        "params": {"textDocument": {"uri": definitionUri}},
      },
    )
    let documentSymbols = readResponse(process.outputStream, 10)
    check documentSymbols != nil
    check documentSymbols["result"].kind == JArray
    check documentSymbols["result"].len == 2
    check documentSymbols["result"][0]["name"].getStr == "smile"
    check documentSymbols["result"][0]["kind"].getInt == 13
    check documentSymbols["result"][0]["selectionRange"]["start"]["line"].getInt == 0
    check documentSymbols["result"][0]["selectionRange"]["start"]["character"].getInt ==
      4
    check documentSymbols["result"][1]["name"].getStr == "helper"
    check documentSymbols["result"][1]["kind"].getInt == 12
    check documentSymbols["result"][1]["range"]["start"]["line"].getInt == 1

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 6,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": definitionUri},
          "position": {"line": 2, "character": 0},
        },
      },
    )
    let definitionResult = readResponse(process.outputStream, 6)
    check definitionResult != nil
    check definitionResult["result"]["uri"].getStr == definitionUri
    check definitionResult["result"]["range"]["start"]["line"].getInt == 1
    check definitionResult["result"]["range"]["start"]["character"].getInt == 5
    check definitionResult["result"]["range"]["end"]["character"].getInt == 11

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 8,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": definitionUri},
          "position": {"line": 1, "character": 5},
        },
      },
    )
    let declarationDefinition = readResponse(process.outputStream, 8)
    check declarationDefinition != nil
    check declarationDefinition["result"]["range"]["start"]["line"].getInt == 1
    check declarationDefinition["result"]["range"]["start"]["character"].getInt == 5

    let referencesUri = "file:///tmp/onim-references.nim"
    let referencesText =
      "proc sum(value: int) =\n  let doubled = value\n  echo doubled\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": referencesUri,
            "languageId": "nim",
            "version": 1,
            "text": referencesText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 11,
        "method": "textDocument/references",
        "params": {
          "textDocument": {"uri": referencesUri},
          "position": {"line": 1, "character": 16},
          "context": {"includeDeclaration": true},
        },
      },
    )
    let referencesResult = readResponse(process.outputStream, 11)
    check referencesResult != nil
    check referencesResult["result"].kind == JArray
    check referencesResult["result"].len == 2
    check referencesResult["result"][0]["range"]["start"]["line"].getInt == 0
    check referencesResult["result"][0]["range"]["start"]["character"].getInt == 9
    check referencesResult["result"][1]["range"]["start"]["line"].getInt == 1
    check referencesResult["result"][1]["range"]["start"]["character"].getInt == 16

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 12,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": referencesUri},
          "position": {"line": 1, "character": 16},
        },
      },
    )
    let localDefinition = readResponse(process.outputStream, 12)
    check localDefinition != nil
    check localDefinition["result"]["uri"].getStr == referencesUri
    check localDefinition["result"]["range"]["start"]["line"].getInt == 0
    check localDefinition["result"]["range"]["start"]["character"].getInt == 9

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 13,
        "method": "textDocument/hover",
        "params": {
          "textDocument": {"uri": definitionUri},
          "position": {"line": 2, "character": 1},
        },
      },
    )
    let localHover = readResponse(process.outputStream, 13)
    check localHover != nil
    check localHover["result"]["contents"]["value"].getStr.contains("helper")

    let hoverUri = "file:///tmp/onim-hover.nim"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": hoverUri,
            "languageId": "nim",
            "version": 1,
            "text": "import std/os\nwalkDir(\"/tmp\")\n",
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 14,
        "method": "textDocument/hover",
        "params":
          {"textDocument": {"uri": hoverUri}, "position": {"line": 1, "character": 1}},
      },
    )
    let stdlibHover = readResponse(process.outputStream, 14)
    check stdlibHover != nil
    check stdlibHover["result"]["contents"]["value"].getStr.contains("std/os")

    let providerUri = "file:///tmp/onim-provider/provider.nim"
    let consumerUri = "file:///tmp/onim-provider/consumer.nim"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": providerUri,
            "languageId": "nim",
            "version": 1,
            "text": "proc answer*() = discard\n",
          }
        },
      },
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
            "text": "import provider\nprovider.answer()\n",
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 9,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 9}
        },
      },
    )
    let crossFileDefinition = readResponse(process.outputStream, 9)
    check crossFileDefinition != nil
    check crossFileDefinition["result"]["uri"].getStr == providerUri
    check crossFileDefinition["result"]["range"]["start"]["line"].getInt == 0
    check crossFileDefinition["result"]["range"]["start"]["character"].getInt == 5

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 7,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": definitionUri},
          "position": {"line": 99, "character": 0},
        },
      },
    )
    let invalidDefinition = readResponse(process.outputStream, 7)
    check invalidDefinition != nil
    check invalidDefinition["result"].kind == JNull

    for version in 2 .. 4:
      sendMessage(
        process.inputStream,
        %*{
          "jsonrpc": "2.0",
          "method": "textDocument/didChange",
          "params": {
            "textDocument": {"uri": uri, "version": version},
            "contentChanges": [{"text": readFile(filePath) & "\n# edit " & $version}],
          },
        },
      )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 5,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri}, "context": {"only": ["source.organizeImports"]}
        },
      },
    )
    let changedActions = readResponse(process.outputStream, 5)
    check changedActions != nil
    check changedActions["result"].len == 1
    check changedActions["result"][0]["edit"]["changes"][uri][0]["newText"].getStr.contains(
      "import std/os"
    )

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    let shutdown = readResponse(process.outputStream, 3)
    check shutdown != nil
    check shutdown["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})

  test "bootstraps an unopened project module only for definition":
    let projectRoot = currentSourcePath().parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-bootstrap-" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "provider.nim")
      removeFile(root / "consumer.nim")
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "proc answer*() = discard\n")
    let providerUri = "file://" & providerPath.replace('\\', '/')
    let consumerUri = "file://" & consumerPath.replace('\\', '/')
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process
      removeFile(providerPath)
      if fileExists(consumerPath):
        removeFile(consumerPath)
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
    let initialized = readResponse(process.outputStream, 1)
    check initialized != nil

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
            "text": "import provider\nprovider.answer()\n",
          }
        },
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
    let definitionResult = readResponse(process.outputStream, 2)
    check definitionResult != nil
    check definitionResult["result"]["uri"].getStr == providerUri

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})

  test "publishes native project-import diagnostics on first open":
    let projectRoot = currentSourcePath().parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-project-diagnostic-" & $getCurrentProcessId())
    if dirExists(root):
      for path in walkDirRec(root):
        if fileExists(path):
          removeFile(path)
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let providerUri = "file://" & providerPath.replace('\\', '/')
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
    check resolved["params"]["diagnostics"].len == 0

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 2)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
