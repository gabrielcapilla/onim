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
    let initialized = readMessage(process.outputStream)
    check initialized != nil
    check initialized["result"]["capabilities"]["codeActionProvider"] != nil
    check initialized["result"]["capabilities"]["definitionProvider"].getBool

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
    let actions = readMessage(process.outputStream)
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
    let cachedActions = readMessage(process.outputStream)
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
        "id": 6,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": definitionUri},
          "position": {"line": 2, "character": 0},
        },
      },
    )
    let definitionResult = readMessage(process.outputStream)
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
    let declarationDefinition = readMessage(process.outputStream)
    check declarationDefinition != nil
    check declarationDefinition["result"]["range"]["start"]["line"].getInt == 1
    check declarationDefinition["result"]["range"]["start"]["character"].getInt == 5

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
    let crossFileDefinition = readMessage(process.outputStream)
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
    let invalidDefinition = readMessage(process.outputStream)
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
    let changedActions = readMessage(process.outputStream)
    check changedActions != nil
    check changedActions["result"].len == 1
    check changedActions["result"][0]["edit"]["changes"][uri][0]["newText"].getStr.contains(
      "import std/os"
    )

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    let shutdown = readMessage(process.outputStream)
    check shutdown != nil
    check shutdown["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
