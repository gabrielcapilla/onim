import std/[json, os, osproc, streams, strutils, times, unittest]

proc sendMessage(input: Stream, message: JsonNode) =
  let body = $message
  input.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  input.flush

proc sendRaw(input: Stream, body: string) =
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

proc readDiagnostics(output: Stream, uri: string): JsonNode =
  while true:
    let message = readMessage(output)
    if message == nil:
      return
    if message.hasKey("method") and
        message["method"].getStr == "textDocument/publishDiagnostics" and
        message["params"]["uri"].getStr == uri:
      return message

suite "stdio LSP":
  test "terminates after exit while stdin remains open":
    let root = currentSourcePath().parentDir.parentDir
    let process = startProcess(root / "onim", args = ["--stdio"], workingDir = root)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    )
    check readResponse(process.outputStream, 1) != nil
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 2)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(2000) == 0

  test "cancels a pending semantic code action without blocking the reader":
    let root = currentSourcePath().parentDir.parentDir
    let filePath = getTempDir() / ("onim-cancel-" & $getCurrentProcessId() & ".nim")
    let uri = "file://" & filePath.replace('\\', '/')
    writeFile(filePath, "include missing_module\n\nproc main() = discard\n")
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
        "id": 2,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri}, "context": {"only": ["source.organizeImports"]}
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 2}},
    )
    let started = epochTime()
    let canceled = readResponse(process.outputStream, 2)
    check (epochTime() - started) * 1000.0 < 1000.0
    check canceled != nil
    check canceled["error"]["code"].getInt == -32800

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "reaps the semantic worker between completed fallback requests":
    let root = getTempDir() / ("onim-reap-" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "first.nim")
      removeFile(root / "second.nim")
      removeDir(root)
    createDir(root)
    let firstPath = root / "first.nim"
    let secondPath = root / "second.nim"
    let firstUri = "file://" & firstPath.replace('\\', '/')
    let secondUri = "file://" & secondPath.replace('\\', '/')
    let source =
      "include missing_module\n\nproc main() =\n  for kind, path in walkDir(\"/tmp\"): discard\n"
    writeFile(firstPath, source)
    writeFile(secondPath, source)
    defer:
      removeFile(firstPath)
      removeFile(secondPath)
      removeDir(root)

    let projectRoot = currentSourcePath().parentDir.parentDir
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
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

    for request in [(id: 2, uri: firstUri), (id: 3, uri: secondUri)]:
      sendMessage(
        process.inputStream,
        %*{
          "jsonrpc": "2.0",
          "id": request.id,
          "method": "textDocument/codeAction",
          "params": {
            "textDocument": {"uri": request.uri},
            "context": {"only": ["source.organizeImports"]},
          },
        },
      )
      let actions = readResponse(process.outputStream, request.id)
      check actions != nil
      check actions["result"].kind == JArray
      check actions["result"].len == 1
      check actions["result"][0]["edit"]["changes"][request.uri][0]["newText"].getStr.contains(
        "import std/os"
      )

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 4, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 4)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "drops canceled queued semantic work":
    let root = getTempDir() / ("onim-queue-cancel-" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "first.nim")
      removeFile(root / "canceled.nim")
      removeFile(root / "next.nim")
      removeDir(root)
    createDir(root)
    let firstPath = root / "first.nim"
    let canceledPath = root / "canceled.nim"
    let nextPath = root / "next.nim"
    let firstUri = "file://" & firstPath.replace('\\', '/')
    let canceledUri = "file://" & canceledPath.replace('\\', '/')
    let nextUri = "file://" & nextPath.replace('\\', '/')
    let source =
      "include missing_module\n\nproc main() =\n  for kind, path in walkDir(\"/tmp\"): discard\n"
    writeFile(firstPath, source)
    writeFile(canceledPath, source)
    writeFile(nextPath, source)
    defer:
      removeFile(firstPath)
      removeFile(canceledPath)
      removeFile(nextPath)
      removeDir(root)

    let projectRoot = currentSourcePath().parentDir.parentDir
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
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
    for request in [(id: 2, uri: firstUri), (id: 3, uri: canceledUri)]:
      sendMessage(
        process.inputStream,
        %*{
          "jsonrpc": "2.0",
          "id": request.id,
          "method": "textDocument/codeAction",
          "params": {
            "textDocument": {"uri": request.uri},
            "context": {"only": ["source.organizeImports"]},
          },
        },
      )
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 3}},
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 4,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": nextUri},
          "context": {"only": ["source.organizeImports"]},
        },
      },
    )

    var responses: array[5, JsonNode]
    var remaining = 3
    while remaining > 0:
      let message = readMessage(process.outputStream)
      check message != nil
      if message.hasKey("id") and message["id"].kind == JInt:
        let responseId = message["id"].getInt
        if responseId >= 2 and responseId <= 4 and responses[responseId] == nil:
          responses[responseId] = message
          dec remaining
    check responses[3]["error"]["code"].getInt == -32800
    check responses[2]["result"].len == 1
    check responses[2]["result"][0]["edit"]["changes"][firstUri][0]["newText"].getStr.contains(
      "import std/os"
    )
    check responses[4]["result"].len == 1
    check responses[4]["result"][0]["edit"]["changes"][nextUri][0]["newText"].getStr.contains(
      "import std/os"
    )

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 5, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 5)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "serves native organize imports before compiler availability":
    let root = getTempDir() / ("onim-native-" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "main.nim")
      removeDir(root)
    createDir(root)
    let emptyPath = root / "bin"
    createDir(emptyPath)
    let filePath = root / "main.nim"
    let uri = "file://" & filePath.replace('\\', '/')
    writeFile(
      filePath,
      "proc main() =\n" & "  echo fmt(\"hello\")\n" &
        "  for kind, path in walkDir(\"/tmp\"): discard\n",
    )
    let projectRoot = currentSourcePath().parentDir.parentDir
    let previousPath = getEnv("PATH")
    putEnv("PATH", emptyPath)
    defer:
      putEnv("PATH", previousPath)
      removeFile(filePath)
      removeDir(emptyPath)
      removeDir(root)
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
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
        "id": 2,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": uri}, "context": {"only": ["source.organizeImports"]}
        },
      },
    )
    let actions = readResponse(process.outputStream, 2)
    check actions != nil
    check actions["result"].len == 1
    check actions["result"][0]["edit"]["changes"][uri][0]["newText"].getStr ==
      "import std/[os, strformat]\n\n"
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

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
    check initialized["result"]["capabilities"]["typeDefinitionProvider"].getBool
    check initialized["result"]["capabilities"]["implementationProvider"].getBool
    check initialized["result"]["capabilities"]["callHierarchyProvider"].getBool
    check initialized["result"]["capabilities"]["hoverProvider"].getBool
    check initialized["result"]["capabilities"]["renameProvider"]["prepareProvider"].getBool
    check initialized["result"]["capabilities"]["referencesProvider"].getBool
    check initialized["result"]["capabilities"]["documentSymbolProvider"].getBool
    check initialized["result"]["capabilities"]["documentHighlightProvider"].getBool
    check initialized["result"]["capabilities"]["foldingRangeProvider"].getBool
    check initialized["result"]["capabilities"]["selectionRangeProvider"].getBool
    check initialized["result"]["capabilities"]["signatureHelpProvider"] != nil
    check initialized["result"]["capabilities"]["semanticTokensProvider"] != nil
    check initialized["result"]["capabilities"]["semanticTokensProvider"]["full"].getBool
    check initialized["result"]["capabilities"]["semanticTokensProvider"]["legend"][
      "tokenTypes"
    ].len == 8
    check initialized["result"]["capabilities"]["workspaceSymbolProvider"].getBool
    check initialized["result"]["capabilities"]["inlayHintProvider"].getBool
    check not initialized["result"]["capabilities"]["completionProvider"][
      "resolveProvider"
    ].getBool
    check initialized["result"]["capabilities"]["completionProvider"][
      "triggerCharacters"
    ][0].getStr == "."

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

    let aliasUri = "file:///tmp/onim-alias-action.nim"
    let aliasText = "import std/os as fs\n\nproc main() =\n  discard\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument":
            {"uri": aliasUri, "languageId": "nim", "version": 1, "text": aliasText}
        },
      },
    )
    let aliasDiagnostics = readDiagnostics(process.outputStream, aliasUri)
    check aliasDiagnostics != nil
    check aliasDiagnostics["params"]["diagnostics"].len == 0
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 18,
        "method": "textDocument/codeAction",
        "params": {
          "textDocument": {"uri": aliasUri},
          "context": {"only": ["source.organizeImports"]},
        },
      },
    )
    let aliasAction = readResponse(process.outputStream, 18)
    check aliasAction != nil
    check aliasAction["result"].kind == JArray
    check aliasAction["result"].len == 1
    check aliasAction["result"][0]["edit"]["changes"][aliasUri].len == 1
    check aliasAction["result"][0]["edit"]["changes"][aliasUri][0]["newText"].getStr ==
      ""

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
        "id": 35,
        "method": "textDocument/semanticTokens/full",
        "params": {"textDocument": {"uri": definitionUri}},
      },
    )
    let semantic = readResponse(process.outputStream, 35)
    check semantic != nil
    let semanticData = semantic["result"]["data"]
    check semanticData.kind == JArray
    check semanticData.len >= 20
    check semanticData[0].getInt == 0
    check semanticData[1].getInt == 0
    check semanticData[2].getInt == 3
    check semanticData[3].getInt == 6
    check semanticData[4].getInt == 0
    check semanticData[5].getInt == 0
    check semanticData[6].getInt == 4
    check semanticData[7].getInt == 5
    check semanticData[8].getInt == 3
    check semanticData[9].getInt == 0

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 36,
        "method": "workspace/symbol",
        "params": {"query": "helper"},
      },
    )
    let workspaceSymbols = readResponse(process.outputStream, 36)
    check workspaceSymbols != nil
    check workspaceSymbols["result"].kind == JArray
    var foundHelper = false
    for item in workspaceSymbols["result"].items:
      if item["name"].getStr == "helper" and
          item["location"]["uri"].getStr == definitionUri:
        foundHelper = true
    check foundHelper
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 38,
        "method": "workspace/symbol",
        "params": {"query": "lp"},
      },
    )
    let substringSymbols = readResponse(process.outputStream, 38)
    check substringSymbols != nil
    var foundSubstring = false
    for item in substringSymbols["result"].items:
      if item["name"].getStr == "helper" and
          item["location"]["uri"].getStr == definitionUri:
        foundSubstring = true
    check foundSubstring

    let typeDefinitionUri = "file:///tmp/onim-type-definition.nim"
    let typeDefinitionText =
      "type Person = object\n  name: string\n\nproc show(person: ref Person) =\n  echo person.name\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": typeDefinitionUri,
            "languageId": "nim",
            "version": 1,
            "text": typeDefinitionText,
          }
        },
      },
    )
    check readDiagnostics(process.outputStream, typeDefinitionUri) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 37,
        "method": "textDocument/typeDefinition",
        "params": {
          "textDocument": {"uri": typeDefinitionUri},
          "position": {"line": 3, "character": 12},
        },
      },
    )
    let typeDefinition = readResponse(process.outputStream, 37)
    check typeDefinition != nil
    check typeDefinition["result"]["uri"].getStr == typeDefinitionUri
    check typeDefinition["result"]["range"]["start"]["line"].getInt == 0
    check typeDefinition["result"]["range"]["start"]["character"].getInt == 5

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

    let implementationUri = "file:///tmp/onim-implementation.nim"
    let implementationText =
      "type Left = object\n" & "  value*: int\n" & "type Right = object\n" &
      "  value*: int\n" & "method render*(item: Left) = discard\n" &
      "method render*(item: Right) = discard\n" &
      "proc use(item: Left) = discard item.render()\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": implementationUri,
            "languageId": "nim",
            "version": 1,
            "text": implementationText,
          }
        },
      },
    )
    check readDiagnostics(process.outputStream, implementationUri) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 39,
        "method": "textDocument/implementation",
        "params": {
          "textDocument": {"uri": implementationUri},
          "position": {
            "line": 6, "character": implementationText.splitLines[6].find("render") + 1
          },
        },
      },
    )
    let implementations = readResponse(process.outputStream, 39)
    check implementations != nil
    check implementations["result"].kind == JArray
    check implementations["result"].len == 1
    check implementations["result"][0]["uri"].getStr == implementationUri
    check implementations["result"][0]["range"]["start"]["line"].getInt == 4
    check implementations["result"][0]["range"]["start"]["character"].getInt == 7

    let hierarchyUri = "file:///tmp/onim-hierarchy.nim"
    let hierarchyText = "proc leaf*() = discard\n" & "proc caller() =\n" & "  leaf()\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": hierarchyUri,
            "languageId": "nim",
            "version": 1,
            "text": hierarchyText,
          }
        },
      },
    )
    check readDiagnostics(process.outputStream, hierarchyUri) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 40,
        "method": "textDocument/prepareCallHierarchy",
        "params": {
          "textDocument": {"uri": hierarchyUri},
          "position":
            {"line": 0, "character": hierarchyText.splitLines[0].find("leaf") + 1},
        },
      },
    )
    let leafItem = readResponse(process.outputStream, 40)
    check leafItem != nil
    check leafItem["result"].kind == JArray
    check leafItem["result"].len == 1
    check leafItem["result"][0]["name"].getStr == "leaf"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 41,
        "method": "callHierarchy/incomingCalls",
        "params": {"item": leafItem["result"][0]},
      },
    )
    let incoming = readResponse(process.outputStream, 41)
    check incoming != nil
    check incoming["result"].kind == JArray
    check incoming["result"].len == 1
    check incoming["result"][0]["from"]["name"].getStr == "caller"
    check incoming["result"][0]["fromRanges"][0]["start"]["line"].getInt == 2
    check incoming["result"][0]["fromRanges"][0]["start"]["character"].getInt == 2
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 42,
        "method": "textDocument/prepareCallHierarchy",
        "params": {
          "textDocument": {"uri": hierarchyUri},
          "position":
            {"line": 1, "character": hierarchyText.splitLines[1].find("caller") + 1},
        },
      },
    )
    let callerItem = readResponse(process.outputStream, 42)
    check callerItem != nil
    check callerItem["result"].len == 1
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 43,
        "method": "callHierarchy/outgoingCalls",
        "params": {"item": callerItem["result"][0]},
      },
    )
    let outgoing = readResponse(process.outputStream, 43)
    check outgoing != nil
    check outgoing["result"].kind == JArray
    check outgoing["result"].len == 1
    check outgoing["result"][0]["to"]["name"].getStr == "leaf"
    check outgoing["result"][0]["fromRanges"][0]["start"]["line"].getInt == 2
    check outgoing["result"][0]["fromRanges"][0]["start"]["character"].getInt == 2

    let highlightUri = "file:///tmp/onim-highlight.nim"
    let highlightText = "proc main() =\n  let value = 1\n  echo value\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": highlightUri,
            "languageId": "nim",
            "version": 1,
            "text": highlightText,
          }
        },
      },
    )
    check readDiagnostics(process.outputStream, highlightUri) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 32,
        "method": "textDocument/inlayHint",
        "params": {
          "textDocument": {"uri": highlightUri},
          "range":
            {"start": {"line": 0, "character": 0}, "end": {"line": 3, "character": 0}},
        },
      },
    )
    let inlays = readResponse(process.outputStream, 32)
    check inlays != nil
    check inlays["result"].kind == JArray
    check inlays["result"].len == 1
    check inlays["result"][0]["label"].getStr == ": int"
    check inlays["result"][0]["kind"].getInt == 1
    check inlays["result"][0]["position"]["line"].getInt == 1
    check inlays["result"][0]["position"]["character"].getInt == 11
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 30,
        "method": "textDocument/documentHighlight",
        "params": {
          "textDocument": {"uri": highlightUri}, "position": {"line": 2, "character": 7}
        },
      },
    )
    let highlights = readResponse(process.outputStream, 30)
    check highlights != nil
    check highlights["result"].kind == JArray
    check highlights["result"].len == 2
    check highlights["result"][0]["kind"].getInt == 1
    check highlights["result"][0]["range"]["start"]["line"].getInt == 1
    check highlights["result"][0]["range"]["start"]["character"].getInt == 6
    check highlights["result"][1]["range"]["start"]["line"].getInt == 2
    check highlights["result"][1]["range"]["start"]["character"].getInt == 7

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 31,
        "method": "textDocument/foldingRange",
        "params": {"textDocument": {"uri": highlightUri}},
      },
    )
    let folds = readResponse(process.outputStream, 31)
    check folds != nil
    check folds["result"].kind == JArray
    check folds["result"].len == 1
    check folds["result"][0]["startLine"].getInt == 0
    check folds["result"][0]["endLine"].getInt == 2

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 32,
        "method": "textDocument/selectionRange",
        "params": {
          "textDocument": {"uri": highlightUri},
          "positions": [{"line": 2, "character": 7}],
        },
      },
    )
    let selections = readResponse(process.outputStream, 32)
    check selections != nil
    check selections["result"].kind == JArray
    check selections["result"].len == 1
    check selections["result"][0]["range"]["start"]["line"].getInt == 2
    check selections["result"][0]["range"]["start"]["character"].getInt == 7
    check selections["result"][0]["parent"]["range"]["start"]["line"].getInt == 0

    let signatureUri = "file:///tmp/onim-signature.nim"
    let signatureText =
      "proc add(left: int, right: int): int = left + right\n" &
      "proc main() =\n  discard add(1, \n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": signatureUri,
            "languageId": "nim",
            "version": 1,
            "text": signatureText,
          }
        },
      },
    )
    check readDiagnostics(process.outputStream, signatureUri) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 33,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": signatureUri},
          "position": {"line": 2, "character": 17},
        },
      },
    )
    let signature = readResponse(process.outputStream, 33)
    check signature != nil
    check signature["result"]["signatures"].len == 1
    check signature["result"]["signatures"][0]["label"].getStr.contains(
      "proc add(left: int, right: int): int"
    )
    check signature["result"]["signatures"][0]["parameters"].len == 2
    check signature["result"]["activeParameter"].getInt == 1

    let overloadSignatureUri = "file:///tmp/onim-overload-signature.nim"
    let overloadSignatureText =
      "proc run(value: int) = discard\n" & "proc run(value: string) = discard\n" &
      "proc main() =\n  discard run(\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": overloadSignatureUri,
            "languageId": "nim",
            "version": 1,
            "text": overloadSignatureText,
          }
        },
      },
    )
    check readDiagnostics(process.outputStream, overloadSignatureUri) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 35,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": overloadSignatureUri},
          "position": {"line": 3, "character": 14},
        },
      },
    )
    let overloadSignature = readResponse(process.outputStream, 35)
    check overloadSignature != nil
    check overloadSignature["result"]["signatures"].len == 2
    let overloadLabels = [
      overloadSignature["result"]["signatures"][0]["label"].getStr,
      overloadSignature["result"]["signatures"][1]["label"].getStr,
    ]
    check overloadLabels[0].contains("proc run(value: int)") or
      overloadLabels[1].contains("proc run(value: int)")
    check overloadLabels[0].contains("proc run(value: string)") or
      overloadLabels[1].contains("proc run(value: string)")
    check overloadSignature["result"]["activeParameter"].getInt == 0

    let stdlibSignatureUri = "file:///tmp/onim-stdlib-signature.nim"
    let stdlibSignatureText = "import std/os\nproc main() =\n  discard walkDir(\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": stdlibSignatureUri,
            "languageId": "nim",
            "version": 1,
            "text": stdlibSignatureText,
          }
        },
      },
    )
    check readDiagnostics(process.outputStream, stdlibSignatureUri) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 34,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": stdlibSignatureUri},
          "position": {"line": 2, "character": 18},
        },
      },
    )
    let stdlibSignature = readResponse(process.outputStream, 34)
    check stdlibSignature != nil
    check stdlibSignature["result"]["signatures"].len >= 1
    check stdlibSignature["result"]["signatures"][0]["label"].getStr.contains("walkDir")
    check stdlibSignature["result"]["signatures"][0]["parameters"].len >= 1

    let aliasedStdlibSignatureUri = "file:///tmp/onim-aliased-stdlib-signature.nim"
    let aliasedStdlibSignatureText =
      "from std/os import walkDir as visit\nproc main() =\n  discard visit(\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": aliasedStdlibSignatureUri,
            "languageId": "nim",
            "version": 1,
            "text": aliasedStdlibSignatureText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 109,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": aliasedStdlibSignatureUri},
          "position": {"line": 2, "character": 16},
        },
      },
    )
    let aliasedStdlibSignature = readResponse(process.outputStream, 109)
    check aliasedStdlibSignature != nil
    check aliasedStdlibSignature["result"]["signatures"].len >= 1
    check aliasedStdlibSignature["result"]["signatures"][0]["label"].getStr.contains(
      "walkDir"
    )
    check aliasedStdlibSignature["result"]["signatures"][0]["parameters"].len >= 1
    check aliasedStdlibSignature["result"]["activeParameter"].getInt == 0

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

    let completionUri = "file:///tmp/onim-completion.nim"
    let completionText =
      "proc show(value: int) =\n  let localValue = value\n  const constantValue = 1\n  echo 😀 loc\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": completionUri,
            "languageId": "nim",
            "version": 1,
            "text": completionText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 16,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": completionUri},
          "position": {"line": 3, "character": 13},
        },
      },
    )
    let completionResult = readResponse(process.outputStream, 16)
    check completionResult != nil
    check completionResult["result"]["isIncomplete"].getBool
    check completionResult["result"]["items"].len == 1
    check completionResult["result"]["items"][0]["label"].getStr == "localValue"
    check completionResult["result"]["items"][0]["kind"].getInt == 6
    check completionResult["result"]["items"][0]["textEdit"]["range"]["start"]["line"].getInt ==
      3
    check completionResult["result"]["items"][0]["textEdit"]["range"]["start"][
      "character"
    ].getInt == 10
    check completionResult["result"]["items"][0]["textEdit"]["range"]["end"][
      "character"
    ].getInt == 13

    let changedCompletionText =
      "proc show(value: int) =\n  let localValue = value\n  const constantValue = 1\n  echo con\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": completionUri, "version": 2},
          "contentChanges": [{"text": changedCompletionText}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 17,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": completionUri},
          "position": {"line": 3, "character": 10},
        },
      },
    )
    let changedCompletionResult = readResponse(process.outputStream, 17)
    check changedCompletionResult != nil
    check changedCompletionResult["result"]["items"].len == 1
    check changedCompletionResult["result"]["items"][0]["label"].getStr ==
      "constantValue"
    check changedCompletionResult["result"]["items"][0]["kind"].getInt == 21

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
        "id": 104,
        "method": "textDocument/prepareRename",
        "params": {
          "textDocument": {"uri": referencesUri},
          "position": {"line": 1, "character": 16},
        },
      },
    )
    let preparedLocalRename = readResponse(process.outputStream, 104)
    check preparedLocalRename != nil
    check preparedLocalRename["result"]["start"]["line"].getInt == 1
    check preparedLocalRename["result"]["start"]["character"].getInt == 16
    check preparedLocalRename["result"]["end"]["line"].getInt == 1
    check preparedLocalRename["result"]["end"]["character"].getInt == 21

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

    let typedHoverUri = "file:///tmp/onim-typed-hover.nim"
    let typedHoverText = "proc show() =\n  let smile = \"😀\"\n  discard smile\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": typedHoverUri,
            "languageId": "nim",
            "version": 1,
            "text": typedHoverText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 19,
        "method": "textDocument/hover",
        "params": {
          "textDocument": {"uri": typedHoverUri},
          "position": {"line": 1, "character": 7},
        },
      },
    )
    let typedLocalHover = readResponse(process.outputStream, 19)
    check typedLocalHover != nil
    check typedLocalHover["result"]["contents"]["value"].getStr ==
      "```nim\nlet smile: string\n```"

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
    check stdlibHover["result"]["contents"]["value"].getStr.contains("Walks over")

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 15,
        "method": "textDocument/rename",
        "params": {
          "textDocument": {"uri": referencesUri},
          "position": {"line": 1, "character": 16},
          "newName": "scaled",
        },
      },
    )
    let renameResult = readResponse(process.outputStream, 15)
    check renameResult != nil
    check renameResult["result"]["changes"][referencesUri].kind == JArray
    check renameResult["result"]["changes"][referencesUri].len == 2
    check renameResult["result"]["changes"][referencesUri][0]["newText"].getStr ==
      "scaled"

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

    let overloadProviderUri = "file:///tmp/onim-provider/overload_provider.nim"
    let overloadConsumerUri = "file:///tmp/onim-provider/overload_consumer.nim"
    let overloadProviderText =
      "proc run*(value: int) = discard\n" & "proc run*(value: string) = discard\n" &
      "proc run(value: float) = discard\n"
    let overloadConsumerText =
      "import overload_provider\nproc main() =\n  discard overload_provider.run(\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": overloadProviderUri,
            "languageId": "nim",
            "version": 1,
            "text": overloadProviderText,
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
            "uri": overloadConsumerUri,
            "languageId": "nim",
            "version": 1,
            "text": overloadConsumerText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 106,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": overloadConsumerUri},
          "position": {"line": 2, "character": 32},
        },
      },
    )
    let projectOverloads = readResponse(process.outputStream, 106)
    check projectOverloads != nil
    check projectOverloads["result"]["signatures"].len == 2
    check projectOverloads["result"]["signatures"][0]["label"].getStr.contains(
      "proc run*(value: int)"
    )
    check projectOverloads["result"]["signatures"][1]["label"].getStr.contains(
      "proc run*(value: string)"
    )
    check projectOverloads["result"]["activeParameter"].getInt == 0

    let fromOverloadConsumerUri = "file:///tmp/onim-provider/from_overload_consumer.nim"
    let fromOverloadConsumerText =
      "from overload_provider import run\nproc main() =\n  discard run(\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": fromOverloadConsumerUri,
            "languageId": "nim",
            "version": 1,
            "text": fromOverloadConsumerText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 107,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": fromOverloadConsumerUri},
          "position": {"line": 2, "character": 14},
        },
      },
    )
    let fromProjectOverloads = readResponse(process.outputStream, 107)
    check fromProjectOverloads != nil
    check fromProjectOverloads["result"]["signatures"].len == 2
    check fromProjectOverloads["result"]["signatures"][0]["label"].getStr.contains(
      "proc run*(value: int)"
    )
    check fromProjectOverloads["result"]["signatures"][1]["label"].getStr.contains(
      "proc run*(value: string)"
    )
    check fromProjectOverloads["result"]["activeParameter"].getInt == 0

    let aliasedOverloadConsumerUri =
      "file:///tmp/onim-provider/aliased_overload_consumer.nim"
    let aliasedOverloadConsumerText =
      "from overload_provider import run as execute\n" &
      "proc main() =\n  discard execute(\n"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": aliasedOverloadConsumerUri,
            "languageId": "nim",
            "version": 1,
            "text": aliasedOverloadConsumerText,
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 108,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": aliasedOverloadConsumerUri},
          "position": {"line": 2, "character": 18},
        },
      },
    )
    let aliasedProjectOverloads = readResponse(process.outputStream, 108)
    check aliasedProjectOverloads != nil
    check aliasedProjectOverloads["result"]["signatures"].len == 2
    check aliasedProjectOverloads["result"]["signatures"][0]["label"].getStr.contains(
      "proc run*(value: int)"
    )
    check aliasedProjectOverloads["result"]["signatures"][1]["label"].getStr.contains(
      "proc run*(value: string)"
    )
    check aliasedProjectOverloads["result"]["activeParameter"].getInt == 0

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 105,
        "method": "textDocument/prepareRename",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 9}
        },
      },
    )
    let preparedCrossFileRename = readResponse(process.outputStream, 105)
    check preparedCrossFileRename != nil
    check preparedCrossFileRename["result"]["start"]["line"].getInt == 1
    check preparedCrossFileRename["result"]["start"]["character"].getInt == 9
    check preparedCrossFileRename["result"]["end"]["line"].getInt == 1
    check preparedCrossFileRename["result"]["end"]["character"].getInt == 15

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
    check process.waitForExit(3000) == 0

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
    writeFile(consumerPath, "import provider\nprovider.answer()\n")
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
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 4,
        "method": "textDocument/references",
        "params": {
          "textDocument": {"uri": consumerUri},
          "position": {"line": 1, "character": 9},
          "context": {"includeDeclaration": true},
        },
      },
    )
    let definitionResult = readResponse(process.outputStream, 2)
    check definitionResult != nil
    check definitionResult["result"]["uri"].getStr == providerUri
    let crossFileReferences = readResponse(process.outputStream, 4)
    check crossFileReferences != nil
    check crossFileReferences["result"].kind == JArray
    check crossFileReferences["result"].len == 2
    check crossFileReferences["result"][0]["uri"].getStr == consumerUri
    check crossFileReferences["result"][0]["range"]["start"]["character"].getInt == 9
    check crossFileReferences["result"][1]["uri"].getStr == providerUri
    check crossFileReferences["result"][1]["range"]["start"]["character"].getInt == 5

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": consumerUri, "version": 2},
          "contentChanges": [{"text": "import provider\nprovider.an\n"}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 7,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 11}
        },
      },
    )
    let projectCompletion = readResponse(process.outputStream, 7)
    check projectCompletion != nil
    check projectCompletion["result"]["items"].len == 1
    check projectCompletion["result"]["items"][0]["label"].getStr == "answer"
    check projectCompletion["result"]["items"][0]["kind"].getInt == 3
    check projectCompletion["result"]["items"][0]["textEdit"]["range"]["start"][
      "character"
    ].getInt == 9
    check projectCompletion["result"]["items"][0]["textEdit"]["range"]["end"][
      "character"
    ].getInt == 11

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": consumerUri, "version": 3},
          "contentChanges": [
            {
              "text":
                "import provider as result\nproc use(): int =\n  result.answer()\n"
            }
          ],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 8,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 2, "character": 9}
        },
      },
    )
    let implicitResultCompletion = readResponse(process.outputStream, 8)
    check implicitResultCompletion != nil
    check implicitResultCompletion["result"].kind == JNull

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 6,
        "method": "textDocument/references",
        "params": {
          "textDocument": {"uri": consumerUri},
          "position": {"line": 2, "character": 9},
          "context": {"includeDeclaration": true},
        },
      },
    )
    let implicitResultReferences = readResponse(process.outputStream, 6)
    check implicitResultReferences != nil
    check implicitResultReferences["result"].kind == JNull

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "bootstraps native cross-file rename with unopened dependents":
    let projectRoot = currentSourcePath().parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-rename-" & $getCurrentProcessId())
    if dirExists(root):
      for path in walkDirRec(root):
        if fileExists(path):
          removeFile(path)
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let aliasPath = root / "alias_consumer.nim"
    let fromPath = root / "from_consumer.nim"
    let unusedPath = root / "unused_consumer.nim"
    let providerSource = "proc answer*() = discard\nproc useAnswer() =\n  answer()\n"
    let aliasSource =
      "import provider as p\nproc useAlias() =\n  echo \"😀\"; p.answer()\n"
    let fromSource = "from provider import answer\nproc useFrom() =\n  answer()\n"
    let unusedSource = "from provider import answer\n"
    writeFile(providerPath, providerSource)
    writeFile(aliasPath, aliasSource)
    writeFile(fromPath, fromSource)
    writeFile(unusedPath, unusedSource)
    let providerUri = "file://" & providerPath.replace('\\', '/')
    let aliasUri = "file://" & aliasPath.replace('\\', '/')
    let fromUri = "file://" & fromPath.replace('\\', '/')
    let unusedUri = "file://" & unusedPath.replace('\\', '/')
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process
      for path in [providerPath, aliasPath, fromPath, unusedPath]:
        if fileExists(path):
          removeFile(path)
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
          "textDocument":
            {"uri": aliasUri, "languageId": "nim", "version": 1, "text": aliasSource}
        },
      },
    )
    discard readMessage(process.outputStream)
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/rename",
        "params": {
          "textDocument": {"uri": aliasUri},
          "position": {"line": 2, "character": 17},
          "newName": "response",
        },
      },
    )
    let renameResult = readResponse(process.outputStream, 2)
    check renameResult != nil
    let changes = renameResult["result"]["changes"]
    check changes.len == 4
    check changes[providerUri].len == 2
    check changes[aliasUri].len == 1
    check changes[fromUri].len == 2
    check changes[unusedUri].len == 1
    check changes[providerUri][0]["range"]["start"]["character"].getInt == 5
    check changes[providerUri][0]["range"]["end"]["character"].getInt == 11
    check changes[providerUri][1]["range"]["start"]["character"].getInt == 2
    check changes[providerUri][1]["range"]["end"]["character"].getInt == 8
    check changes[aliasUri][0]["range"]["start"]["character"].getInt == 15
    check changes[aliasUri][0]["range"]["end"]["character"].getInt == 21
    check changes[fromUri][0]["range"]["start"]["line"].getInt == 0
    check changes[fromUri][0]["range"]["start"]["character"].getInt == 21
    check changes[fromUri][1]["range"]["start"]["character"].getInt == 2
    check changes[unusedUri][0]["range"]["start"]["character"].getInt == 21
    for uri in [providerUri, aliasUri, fromUri, unusedUri]:
      for edit in changes[uri].items:
        check edit["newText"].getStr == "response"

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "textDocument/rename",
        "params": {
          "textDocument": {"uri": aliasUri},
          "position": {"line": 2, "character": 17},
          "newName": "response.next",
        },
      },
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 5,
        "method": "textDocument/prepareCallHierarchy",
        "params": {
          "textDocument": {"uri": providerUri},
          "position": {"line": 0, "character": providerSource.find("answer") + 1},
        },
      },
    )
    let preparedAnswer = readResponse(process.outputStream, 5)
    check preparedAnswer != nil
    check preparedAnswer["result"].kind == JArray
    check preparedAnswer["result"].len == 1
    check preparedAnswer["result"][0]["name"].getStr == "answer"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 6,
        "method": "callHierarchy/incomingCalls",
        "params": {"item": preparedAnswer["result"][0]},
      },
    )
    let incoming = readResponse(process.outputStream, 6)
    check incoming != nil
    check incoming["result"].kind == JArray
    var incomingNames: seq[string] = @[]
    for call in incoming["result"].items:
      incomingNames.add call["from"]["name"].getStr
    check "useAnswer" in incomingNames
    check "useAlias" in incomingNames
    check "useFrom" in incomingNames
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 7,
        "method": "textDocument/prepareCallHierarchy",
        "params": {
          "textDocument": {"uri": aliasUri},
          "position":
            {"line": 1, "character": aliasSource.splitLines[1].find("useAlias") + 1},
        },
      },
    )
    let preparedAlias = readResponse(process.outputStream, 7)
    check preparedAlias != nil
    check preparedAlias["result"].kind == JArray
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 8,
        "method": "callHierarchy/outgoingCalls",
        "params": {"item": preparedAlias["result"][0]},
      },
    )
    let outgoing = readResponse(process.outputStream, 8)
    check outgoing != nil
    check outgoing["result"].kind == JArray
    check outgoing["result"].len == 1
    check outgoing["result"][0]["to"]["name"].getStr == "answer"
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 4, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 4)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "returns resolved document links for imports and includes":
    let repoRoot = currentSourcePath().parentDir.parentDir
    let projectRoot = getTempDir() / ("onim-document-links-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-document-links-cache-" & $getCurrentProcessId())
    if dirExists(projectRoot):
      removeDir(projectRoot)
    if dirExists(cacheRoot):
      removeDir(cacheRoot)
    createDir(projectRoot)
    let providerPath = projectRoot / "link_provider.nim"
    let partPath = projectRoot / "link_part.nim"
    let consumerPath = projectRoot / "link_consumer.nim"
    let consumer = "import link_provider\ninclude link_part\nlink_provider.answer()\n"
    writeFile(providerPath, "proc answer*() = discard\n")
    writeFile(partPath, "const partValue = 1\n")
    writeFile(consumerPath, consumer)
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      if fileExists(providerPath):
        removeFile(providerPath)
      if fileExists(partPath):
        removeFile(partPath)
      if fileExists(consumerPath):
        removeFile(consumerPath)
      if dirExists(projectRoot):
        removeDir(projectRoot)
      if dirExists(cacheRoot):
        removeDir(cacheRoot)

    let uri = "file://" & consumerPath.replace('\\', '/')
    let process =
      startProcess(repoRoot / "onim", args = ["--stdio"], workingDir = repoRoot)
    defer:
      close process
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": "file://" & projectRoot.replace('\\', '/')},
      },
    )
    let initialized = readResponse(process.outputStream, 1)
    check initialized["result"]["capabilities"]["documentLinkProvider"][
      "resolveProvider"
    ].getBool == false
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
            {"uri": uri, "languageId": "nim", "version": 1, "text": consumer}
        },
      },
    )
    discard readDiagnostics(process.outputStream, uri)
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/definition",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 2, "character": 14}},
      },
    )
    check readResponse(process.outputStream, 2) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "textDocument/documentLink",
        "params": {"textDocument": {"uri": uri}},
      },
    )
    let links = readResponse(process.outputStream, 3)
    check links["result"].len == 2
    check links["result"][0]["range"]["start"]["line"].getInt == 0
    check links["result"][0]["range"]["start"]["character"].getInt == 7
    check links["result"][0]["range"]["end"]["character"].getInt == 20
    check links["result"][0]["target"].getStr ==
      "file://" & providerPath.replace('\\', '/')
    check links["result"][1]["range"]["start"]["line"].getInt == 1
    check links["result"][1]["range"]["start"]["character"].getInt == 8
    check links["result"][1]["range"]["end"]["character"].getInt == 17
    check links["result"][1]["target"].getStr == "file://" & partPath.replace('\\', '/')
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 4, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 4)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

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

  test "returns native field completion with UTF-16 ranges":
    let projectRoot = currentSourcePath().parentDir.parentDir
    let uri = "file:///tmp/onim-native-field-completion.nim"
    let source = """type
  Person = object
    name: string

proc show(person: Person) =
  echo 😀 person.na
"""
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 101,
        "method": "initialize",
        "params": {"rootUri": "file://" & projectRoot.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 101) != nil
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
            {"uri": uri, "languageId": "nim", "version": 1, "text": source}
        },
      },
    )
    let diagnostics = readMessage(process.outputStream)
    check diagnostics != nil
    check diagnostics["method"].getStr == "textDocument/publishDiagnostics"

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 102,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 5, "character": 19}},
      },
    )
    let completion = readResponse(process.outputStream, 102)
    check completion != nil
    check completion["result"]["isIncomplete"].getBool
    check completion["result"]["items"].len == 1
    check completion["result"]["items"][0]["label"].getStr == "name"
    check completion["result"]["items"][0]["kind"].getInt == 5
    check completion["result"]["items"][0]["textEdit"]["range"]["start"]["character"].getInt ==
      17
    check completion["result"]["items"][0]["textEdit"]["range"]["end"]["character"].getInt ==
      19

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 103, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 103)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "validates JSON-RPC envelopes and gates shutdown":
    let root = currentSourcePath().parentDir.parentDir
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
    let root = currentSourcePath().parentDir.parentDir
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

  test "cancels a pending workspace request":
    let projectRoot = currentSourcePath().parentDir.parentDir
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
    let root = currentSourcePath().parentDir.parentDir
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
