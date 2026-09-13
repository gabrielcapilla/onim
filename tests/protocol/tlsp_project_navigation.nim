import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import onim/protocol/uris
import harness/stdio

suite "stdio LSP project navigation":
  test "bootstraps an unopened project module for navigation":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-bootstrap+" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "provider.nim")
      removeFile(root / "consumer.nim")
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    writeFile(providerPath, "proc answer*() = discard\n")
    writeFile(consumerPath, "import provider\nprovider.answer()\n")
    let providerResponseUri = fileUri(providerPath)
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
        "id": 10,
        "method": "textDocument/hover",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 9}
        },
      },
    )
    let firstHover = readResponse(process.outputStream, 10)
    check firstHover != nil
    let firstHoverText = firstHover["result"]["contents"]["value"].getStr
    check firstHoverText.contains("proc answer*() = discard")
    check firstHoverText.contains("*Module:* `provider`")
    check firstHoverText.contains("*Declared at line:* 1")
    check firstHover["result"]["range"]["start"]["line"].getInt == 1
    check firstHover["result"]["range"]["start"]["character"].getInt == 9
    check firstHover["result"]["range"]["end"]["line"].getInt == 1
    check firstHover["result"]["range"]["end"]["character"].getInt == 15

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 5,
        "method": "workspace/symbol",
        "params": {"query": "answer"},
      },
    )
    let workspaceSymbolsResult = readResponse(process.outputStream, 5)
    check workspaceSymbolsResult != nil
    check workspaceSymbolsResult["result"].kind == JArray
    check workspaceSymbolsResult["result"].len == 1
    check workspaceSymbolsResult["result"][0]["name"].getStr == "answer"
    check workspaceSymbolsResult["result"][0]["kind"].getInt == 12
    check workspaceSymbolsResult["result"][0]["location"]["uri"].getStr ==
      providerResponseUri
    check workspaceSymbolsResult["result"][0]["location"]["range"]["start"]["line"].getInt ==
      0
    check workspaceSymbolsResult["result"][0]["location"]["range"]["start"]["character"].getInt ==
      5
    check workspaceSymbolsResult["result"][0]["location"]["range"]["end"]["character"].getInt ==
      11

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
    check definitionResult["result"]["uri"].getStr == providerResponseUri
    let crossFileReferences = readResponse(process.outputStream, 4)
    check crossFileReferences != nil
    check crossFileReferences["result"].kind == JArray
    check crossFileReferences["result"].len == 2
    check crossFileReferences["result"][0]["uri"].getStr == consumerUri
    check crossFileReferences["result"][0]["range"]["start"]["character"].getInt == 9
    check crossFileReferences["result"][1]["uri"].getStr == providerResponseUri
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
          "textDocument": {"uri": consumerUri, "version": 4},
          "contentChanges": [{"text": "proc use(): int =\n  ans\n"}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 9,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 5}
        },
      },
    )
    let projectAutoImport = readResponse(process.outputStream, 9)
    check projectAutoImport != nil
    var answerAutoImport: JsonNode
    for item in projectAutoImport["result"]["items"].items:
      if item["label"].getStr == "answer":
        answerAutoImport = item
    check answerAutoImport != nil
    check answerAutoImport["additionalTextEdits"].len == 1
    check answerAutoImport["additionalTextEdits"][0]["newText"].getStr.contains(
      "import provider"
    )

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

  test "bootstraps signature help for an unopened project module":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-signature-" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "provider.nim")
      removeFile(root / "consumer.nim")
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let providerUri = fileUri(providerPath)
    let consumerUri = fileUri(consumerPath)
    let consumerText = "import provider\n  discard provider.add(1, \"\")\n"
    writeFile(providerPath, "proc add*(left: int, right: string): bool = true\n")
    writeFile(consumerPath, consumerText)
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
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": consumerUri, "languageId": "nim", "version": 1, "text": consumerText
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/signatureHelp",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 25}
        },
      },
    )
    let signature = readResponse(process.outputStream, 2)
    check signature != nil
    check signature["result"]["signatures"].len == 1
    check signature["result"]["signatures"][0]["label"].getStr.contains(
      "proc add*(left: int, right: string): bool"
    )
    check signature["result"]["signatures"][0]["parameters"].len == 2
    check signature["result"]["signatures"][0]["parameters"][0]["label"].getStr ==
      "left: int"
    check signature["result"]["signatures"][0]["parameters"][1]["label"].getStr ==
      "right: string"
    check signature["result"]["activeParameter"].getInt == 1

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 3)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "resolves type definitions for imported project values":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-type-definition-" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "provider.nim")
      removeFile(root / "consumer.nim")
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let providerUri = "file://" & providerPath.replace('\\', '/')
    let consumerUri = "file://" & consumerPath.replace('\\', '/')
    let providerText =
      "type Person* = object\n  name*: string\nvar person*: Person\n" &
      "proc makePerson*(): Person = Person()\n"
    let consumerText =
      "import provider\ndiscard provider.person\nlet constructed = provider.makePerson()\ndiscard constructed\n"
    writeFile(providerPath, providerText)
    writeFile(consumerPath, consumerText)
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
        "id": 20,
        "method": "initialize",
        "params": {"rootUri": "file://" & root.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 20) != nil
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument": {
            "uri": consumerUri, "languageId": "nim", "version": 1, "text": consumerText
          }
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 25,
        "method": "textDocument/typeDefinition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 3, "character": 9}
        },
      },
    )
    let returnedTypeDefinition = readResponse(process.outputStream, 25)
    check returnedTypeDefinition != nil
    check returnedTypeDefinition["result"]["uri"].getStr == providerUri
    check returnedTypeDefinition["result"]["range"]["start"]["line"].getInt == 0
    check returnedTypeDefinition["result"]["range"]["start"]["character"].getInt == 5
    check returnedTypeDefinition["result"]["range"]["end"]["line"].getInt == 0
    check returnedTypeDefinition["result"]["range"]["end"]["character"].getInt == 11

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 21,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 17}
        },
      },
    )
    let definition = readResponse(process.outputStream, 21)
    check definition != nil
    check definition["result"]["uri"].getStr == providerUri
    check definition["result"]["range"]["start"]["line"].getInt == 2
    check definition["result"]["range"]["start"]["character"].getInt == 4
    check definition["result"]["range"]["end"]["character"].getInt == 10

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 22,
        "method": "textDocument/typeDefinition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 17}
        },
      },
    )
    let typeDefinition = readResponse(process.outputStream, 22)
    check typeDefinition != nil
    check typeDefinition["result"]["uri"].getStr == providerUri
    check typeDefinition["result"]["range"]["start"]["line"].getInt == 0
    check typeDefinition["result"]["range"]["start"]["character"].getInt == 5
    check typeDefinition["result"]["range"]["end"]["line"].getInt == 0
    check typeDefinition["result"]["range"]["end"]["character"].getInt == 11

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 24,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 2, "character": 27}
        },
      },
    )
    let routineDefinition = readResponse(process.outputStream, 24)
    check routineDefinition != nil
    check routineDefinition["result"]["uri"].getStr == providerUri
    check routineDefinition["result"]["range"]["start"]["line"].getInt == 3
    check routineDefinition["result"]["range"]["start"]["character"].getInt == 5
    check routineDefinition["result"]["range"]["end"]["character"].getInt == 15

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 27,
        "method": "textDocument/hover",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 2, "character": 27}
        },
      },
    )
    let routineHover = readResponse(process.outputStream, 27)
    check routineHover != nil
    let routineHoverText = routineHover["result"]["contents"]["value"].getStr
    check routineHoverText.contains("proc makePerson*(): Person = Person()")
    check routineHoverText.contains("*Module:* `provider`")
    check routineHoverText.contains("*Declared at line:* 4")
    check routineHover["result"]["range"]["start"]["line"].getInt == 2
    check routineHover["result"]["range"]["start"]["character"].getInt == 27
    check routineHover["result"]["range"]["end"]["line"].getInt == 2
    check routineHover["result"]["range"]["end"]["character"].getInt == 37

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 26,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 3, "character": 9}
        },
      },
    )
    let constructedDefinition = readResponse(process.outputStream, 26)
    check constructedDefinition != nil
    check constructedDefinition["result"]["uri"].getStr == consumerUri
    check constructedDefinition["result"]["range"]["start"]["line"].getInt == 2
    check constructedDefinition["result"]["range"]["start"]["character"].getInt == 4
    check constructedDefinition["result"]["range"]["end"]["character"].getInt == 15

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 23, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 23)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "cancels deferred navigation when the document changes":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let root = getTempDir() / ("onim-lsp-invalidation-" & $getCurrentProcessId())
    if dirExists(root):
      removeFile(root / "provider.nim")
      removeFile(root / "consumer.nim")
      removeDir(root)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let providerUri = fileUri(providerPath)
    let consumerUri = fileUri(consumerPath)
    let consumerV1 = "import provider\nprovider.firstNeedle()\n"
    let consumerV2 = "import provider\nprovider.secondNeedle()\n"
    writeFile(
      providerPath, "proc firstNeedle*() = discard\nproc secondNeedle*() = discard\n"
    )
    writeFile(consumerPath, consumerV1)
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
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument":
            {"uri": consumerUri, "languageId": "nim", "version": 1, "text": consumerV1}
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
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 10}
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": consumerUri, "version": 2},
          "contentChanges": [{"text": consumerV2}],
        },
      },
    )
    let cancelled = readResponse(process.outputStream, 2)
    check cancelled != nil
    check cancelled["error"]["code"].getInt == -32801

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "textDocument/definition",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 10}
        },
      },
    )
    let current = readResponse(process.outputStream, 3)
    check current != nil
    check current["result"]["uri"].getStr == providerUri
    check current["result"]["range"]["start"]["line"].getInt == 1
    check current["result"]["range"]["start"]["character"].getInt == 5
    check current["result"]["range"]["end"]["character"].getInt == 17

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 4, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 4)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "bootstraps native cross-file rename with unopened dependents":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
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
