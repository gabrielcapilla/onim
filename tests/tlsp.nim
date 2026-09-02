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
        "params": {"initializationOptions": {"useStdPrefix": true}},
      },
    )
    let initialized = readMessage(process.outputStream)
    check initialized != nil
    check initialized["result"]["capabilities"]["codeActionProvider"] != nil

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
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    let shutdown = readMessage(process.outputStream)
    check shutdown != nil
    check shutdown["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
