import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio

suite "stdio LSP document links":
  test "returns resolved document links for imports and includes":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
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
        "id": 3,
        "method": "textDocument/documentLink",
        "params": {"textDocument": {"uri": uri}},
      },
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
      process.inputStream, %*{"jsonrpc": "2.0", "id": 4, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 4)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0
