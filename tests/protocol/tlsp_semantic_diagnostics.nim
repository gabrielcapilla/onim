import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio

suite "stdio LSP semantic diagnostics":
  test "publishes compiler unused declaration hints asynchronously":
    let binaryRoot = currentSourcePath().parentDir.parentDir.parentDir
    let workspaceRoot =
      getTempDir() / ("onim-unused-workspace-" & $getCurrentProcessId())
    createDir(workspaceRoot)
    defer:
      if dirExists(workspaceRoot):
        removeDir(workspaceRoot)
    let filePath = workspaceRoot / "main.nim"
    let uri = "file://" & filePath.replace('\\', '/')
    let source = "proc unused() = discard\n"
    writeFile(filePath, source)
    defer:
      if fileExists(filePath):
        removeFile(filePath)
    let process =
      startProcess(binaryRoot / "onim", args = ["--stdio"], workingDir = workspaceRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": "file://" & workspaceRoot.replace('\\', '/')},
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
        "params": {"textDocument": {"uri": uri, "version": 1, "text": source}},
      },
    )
    let diagnostics = readUnusedDeclarationDiagnostics(process.outputStream, uri)[
      "params"
    ]["diagnostics"]
    check diagnostics.len == 1
    check diagnostics[0]["code"].getStr == "XDeclaredButNotUsed"
    check diagnostics[0]["severity"].getInt == 2
    check diagnostics[0]["tags"][0].getInt == 1
    check diagnostics[0]["range"]["start"]["line"].getInt == 0
    check diagnostics[0]["range"]["start"]["character"].getInt == 5
    check diagnostics[0]["range"]["end"]["character"].getInt == 11
    check diagnostics[0]["message"].getStr.contains("declared but not used")

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 2)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "drops delayed semantic diagnostics from older document generations":
    let binaryRoot = currentSourcePath().parentDir.parentDir.parentDir
    let workspaceRoot =
      getTempDir() / ("onim-generation-burst-" & $getCurrentProcessId())
    createDir(workspaceRoot)
    defer:
      if dirExists(workspaceRoot):
        removeDir(workspaceRoot)
    let filePath = workspaceRoot / "main.nim"
    let uri = "file://" & filePath.replace('\\', '/')
    let source = "proc stale() = discard\n"
    writeFile(filePath, source)
    defer:
      if fileExists(filePath):
        removeFile(filePath)

    putEnv("ONIM_TEST_SEMANTIC_DELAY_MS", "250")
    putEnv("ONIM_TEST_SEMANTIC_DELAY_GENERATION", "1")
    defer:
      delEnv("ONIM_TEST_SEMANTIC_DELAY_MS")
      delEnv("ONIM_TEST_SEMANTIC_DELAY_GENERATION")

    let process =
      startProcess(binaryRoot / "onim", args = ["--stdio"], workingDir = workspaceRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": "file://" & workspaceRoot.replace('\\', '/')},
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
        "params": {"textDocument": {"uri": uri, "version": 1, "text": source}},
      },
    )
    for item in [
      (version: 2, name: "staleTwo"),
      (version: 3, name: "staleThree"),
      (version: 4, name: "current"),
    ]:
      sendMessage(
        process.inputStream,
        %*{
          "jsonrpc": "2.0",
          "method": "textDocument/didChange",
          "params": {
            "textDocument": {"uri": uri, "version": item.version},
            "contentChanges": [{"text": "proc " & item.name & "() = discard\n"}],
          },
        },
      )

    var unusedVersions: seq[int] = @[]
    for _ in 0 ..< 16:
      let message = readDiagnostics(process.outputStream, uri)
      check message != nil
      var hasUnusedDeclaration = false
      for diagnostic in message["params"]["diagnostics"]:
        if diagnostic.hasKey("code") and diagnostic["code"].kind == JString and
            diagnostic["code"].getStr == "XDeclaredButNotUsed":
          hasUnusedDeclaration = true
      if hasUnusedDeclaration:
        unusedVersions.add message["params"]["version"].getInt
        if unusedVersions[^1] == 4:
          break
    check unusedVersions == @[4]

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 2)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "refreshes semantic diagnostics after an imported module changes":
    let binaryRoot = currentSourcePath().parentDir.parentDir.parentDir
    let workspaceRoot =
      getTempDir() / ("onim-import-change-workspace-" & $getCurrentProcessId())
    createDir(workspaceRoot)
    defer:
      if dirExists(workspaceRoot):
        removeDir(workspaceRoot)
    let providerPath = workspaceRoot / "provider.nim"
    let filePath = workspaceRoot / "main.nim"
    let providerUri = "file://" & providerPath.replace('\\', '/')
    let uri = "file://" & filePath.replace('\\', '/')
    let providerInitial = "template useValue*(value: untyped) = discard value\n"
    let providerChanged = "template useValue*(value: untyped) = discard\n"
    let source = """import provider

proc main() =
  let alwaysUnused = 1
  let local = 2
  useValue(local)

when isMainModule:
  main()
"""
    writeFile(providerPath, providerInitial)
    writeFile(filePath, source)
    defer:
      for path in [providerPath, filePath]:
        if fileExists(path):
          removeFile(path)

    let process =
      startProcess(binaryRoot / "onim", args = ["--stdio"], workingDir = workspaceRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": "file://" & workspaceRoot.replace('\\', '/')},
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
        "params": {"textDocument": {"uri": uri, "version": 1, "text": source}},
      },
    )

    var initialNames: seq[string] = @[]
    for _ in 0 ..< 8:
      let message = readDiagnostics(process.outputStream, uri)
      check message != nil
      for diagnostic in message["params"]["diagnostics"]:
        if diagnostic.hasKey("code") and diagnostic["code"].kind == JString and
            diagnostic["code"].getStr == "XDeclaredButNotUsed":
          initialNames.add diagnostic["message"].getStr
      if initialNames.len > 0:
        break
    check initialNames.len == 1
    check initialNames[0].contains("alwaysUnused")

    writeFile(providerPath, providerChanged)
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "workspace/didChangeWatchedFiles",
        "params": {"changes": [{"uri": providerUri, "type": 2}]},
      },
    )

    var refreshed: JsonNode
    var refreshedNames: seq[string] = @[]
    for _ in 0 ..< 12:
      refreshed = readDiagnostics(process.outputStream, uri)
      check refreshed != nil
      refreshedNames.setLen(0)
      for diagnostic in refreshed["params"]["diagnostics"]:
        if diagnostic.hasKey("code") and diagnostic["code"].kind == JString and
            diagnostic["code"].getStr == "XDeclaredButNotUsed":
          refreshedNames.add diagnostic["message"].getStr
      if refreshedNames.len == 2:
        break
    check refreshed["params"]["version"].getInt == 1
    check refreshedNames.len == 2
    let refreshedText = refreshedNames.join("\n")
    check refreshedText.contains("alwaysUnused")
    check refreshedText.contains("local")

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 2)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "publishes unused declaration diagnostics for stropped identifiers":
    let binaryRoot = currentSourcePath().parentDir.parentDir.parentDir
    let workspaceRoot =
      getTempDir() / ("onim-stropped-diagnostic-workspace-" & $getCurrentProcessId())
    createDir(workspaceRoot)
    defer:
      if dirExists(workspaceRoot):
        removeDir(workspaceRoot)
    let filePath = workspaceRoot / "main.nim"
    let uri = "file://" & filePath.replace('\\', '/')
    let source = "proc normalUnused() = discard\nproc `type`() = discard\n"
    writeFile(filePath, source)
    defer:
      if fileExists(filePath):
        removeFile(filePath)

    let process =
      startProcess(binaryRoot / "onim", args = ["--stdio"], workingDir = workspaceRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "initialize",
        "params": {"rootUri": "file://" & workspaceRoot.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 3) != nil
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {"textDocument": {"uri": uri, "version": 1, "text": source}},
      },
    )
    let diagnostics =
      readUnusedDeclarationDiagnostics(process.outputStream, uri)["params"]
    check diagnostics["version"].getInt == 1
    let values = diagnostics["diagnostics"]
    check values.len == 2
    var normalFound = false
    var stroppedFound = false
    for diagnostic in values:
      check diagnostic["code"].getStr == "XDeclaredButNotUsed"
      check diagnostic["severity"].getInt == 2
      check diagnostic["tags"][0].getInt == 1
      let start = diagnostic["range"]["start"]
      let finish = diagnostic["range"]["end"]
      if start["line"].getInt == 0:
        check start["character"].getInt == 5
        check finish["character"].getInt == 17
        normalFound = true
      elif start["line"].getInt == 1:
        check start["character"].getInt == 5
        check finish["character"].getInt == 11
        stroppedFound = true
    check normalFound
    check stroppedFound

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 4, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 4)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0
