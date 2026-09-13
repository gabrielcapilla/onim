import std/[json, os, osproc, strutils, unittest]

import protocol/feature_session
import protocol/tlsp_feature_organize
import protocol/tlsp_feature_navigation
import protocol/tlsp_feature_text
import protocol/tlsp_feature_interactive
import protocol/tlsp_feature_project
import harness/stdio

suite "stdio LSP feature session":
  test "returns organize-imports workspace edit":
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let session = startFeatureSession(root)
    defer:
      closeFeatureSession(session)

    runFeatureOrganize(session)
    runFeatureNavigation(session)
    runFeatureText(session)
    runFeatureInteractive(session)
    runFeatureProject(session)

    let process = session.process
    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
    )
    let shutdown = readResponse(process.outputStream, 3)
    check shutdown != nil
    check shutdown["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "prepares only supported project renames":
    let binaryRoot = currentSourcePath().parentDir.parentDir.parentDir
    let workspaceRoot =
      getTempDir() / ("onim-rename-workspace-" & $getCurrentProcessId())
    createDir(workspaceRoot)
    defer:
      if dirExists(workspaceRoot):
        removeDir(workspaceRoot)

    let providerPath = workspaceRoot / "provider.nim"
    let consumerPath = workspaceRoot / "consumer.nim"
    let providerUri = "file://" & providerPath.replace('\\', '/')
    let consumerUri = "file://" & consumerPath.replace('\\', '/')
    let providerText = "proc answer*() = discard\nproc hidden() = discard\nhidden()\n"
    let consumerText = "import provider\nprovider.answer()\n"
    writeFile(providerPath, providerText)
    writeFile(consumerPath, consumerText)
    defer:
      if fileExists(providerPath):
        removeFile(providerPath)
      if fileExists(consumerPath):
        removeFile(consumerPath)

    let process =
      startProcess(binaryRoot / "onim", args = ["--stdio"], workingDir = workspaceRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 201,
        "method": "initialize",
        "params": {"rootUri": "file://" & workspaceRoot.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 201) != nil
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
            "uri": providerUri, "languageId": "nim", "version": 1, "text": providerText
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
            "uri": consumerUri, "languageId": "nim", "version": 1, "text": consumerText
          }
        },
      },
    )

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 202,
        "method": "textDocument/prepareRename",
        "params": {
          "textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 9}
        },
      },
    )
    let preparedExported = readResponse(process.outputStream, 202)
    check preparedExported != nil
    check preparedExported["result"]["start"]["line"].getInt == 1
    check preparedExported["result"]["start"]["character"].getInt == 9
    check preparedExported["result"]["end"]["line"].getInt == 1
    check preparedExported["result"]["end"]["character"].getInt == 15

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 203,
        "method": "textDocument/rename",
        "params": {
          "textDocument": {"uri": consumerUri},
          "position": {"line": 1, "character": 9},
          "newName": "display",
        },
      },
    )
    let exportedRename = readResponse(process.outputStream, 203)
    check exportedRename != nil
    check exportedRename["result"].kind == JObject

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 204,
        "method": "textDocument/references",
        "params": {
          "textDocument": {"uri": providerUri},
          "position": {"line": 2, "character": 1},
          "context": {"includeDeclaration": true},
        },
      },
    )
    let privateReferences = readResponse(process.outputStream, 204)
    check privateReferences != nil
    check privateReferences["result"].kind == JArray
    check privateReferences["result"].len == 2
    var privateDeclaration = false
    var privateUse = false
    for location in privateReferences["result"]:
      check location["uri"].getStr == providerUri
      let start = location["range"]["start"]
      let finish = location["range"]["end"]
      if start["line"].getInt == 1 and start["character"].getInt == 5 and
          finish["line"].getInt == 1 and finish["character"].getInt == 11:
        privateDeclaration = true
      if start["line"].getInt == 2 and start["character"].getInt == 0 and
          finish["line"].getInt == 2 and finish["character"].getInt == 6:
        privateUse = true
    check privateDeclaration
    check privateUse

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 205,
        "method": "textDocument/prepareRename",
        "params": {
          "textDocument": {"uri": providerUri}, "position": {"line": 1, "character": 5}
        },
      },
    )
    let preparedPrivate = readResponse(process.outputStream, 205)
    check preparedPrivate != nil
    check preparedPrivate["result"]["start"]["line"].getInt == 1
    check preparedPrivate["result"]["start"]["character"].getInt == 5
    check preparedPrivate["result"]["end"]["line"].getInt == 1
    check preparedPrivate["result"]["end"]["character"].getInt == 11

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 206,
        "method": "textDocument/rename",
        "params": {
          "textDocument": {"uri": providerUri},
          "position": {"line": 1, "character": 5},
          "newName": "display",
        },
      },
    )
    let privateRename = readResponse(process.outputStream, 206)
    check privateRename != nil
    check privateRename["result"].kind == JObject
    check privateRename["result"]["changes"].hasKey(providerUri)
    check not privateRename["result"]["changes"].hasKey(consumerUri)
    check privateRename["result"]["changes"][providerUri].len == 2

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 207, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 207)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0
