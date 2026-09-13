import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio

suite "stdio LSP semantic workers":
  test "cancels a pending semantic code action without blocking the reader":
    let root = currentSourcePath().parentDir.parentDir.parentDir
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

  test "restarts a semantic worker after child termination":
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
    putEnv("ONIM_TEST_SEMANTIC_EXIT_AFTER_RESPONSE", "1")
    defer:
      delEnv("ONIM_TEST_SEMANTIC_EXIT_AFTER_RESPONSE")
      removeFile(firstPath)
      removeFile(secondPath)
      removeDir(root)

    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
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

    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
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
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let toolchain = resolveNimToolchain(projectRoot)
    check toolchain.state == toolchainReady
    let stdlibPath = stdlibBinaryPath(toolchain)
    check fileExists(stdlibPath)
    let previousStdlibPath = getEnv("ONIM_STDLIB_MAP")
    let previousPath = getEnv("PATH")
    putEnv("ONIM_STDLIB_MAP", stdlibPath)
    putEnv("PATH", emptyPath)
    defer:
      if previousStdlibPath.len > 0:
        putEnv("ONIM_STDLIB_MAP", previousStdlibPath)
      else:
        delEnv("ONIM_STDLIB_MAP")
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
