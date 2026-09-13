import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio

suite "stdio LSP lifecycle":
  test "terminates after exit while stdin remains open":
    let root = currentSourcePath().parentDir.parentDir.parentDir
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

  when defined(linux):
    test "repeated stdio sessions exit without retaining the server":
      let root = currentSourcePath().parentDir.parentDir.parentDir
      for _ in 0 ..< 3:
        let process = startProcess(root / "onim", args = ["--stdio"], workingDir = root)
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
        close process

  when defined(linux):
    test "terminates when its launcher exits":
      let root = currentSourcePath().parentDir.parentDir.parentDir
      let command = quoteShell(root / "onim") & " --stdio"
      let wrapper = startProcess(
        "/bin/sh",
        args = ["-c", command & " & echo $!"],
        workingDir = root,
        options = {poUsePath},
      )
      var line = ""
      check wrapper.outputStream.readLine(line)
      check line.len > 0
      let childPid = parseInt(line)
      check wrapper.waitForExit(2000) == 0
      defer:
        if fileExists("/proc/" & $childPid):
          discard startProcess("kill", args = ["-TERM", $childPid]).waitForExit(1000)
      var stopped = false
      for _ in 0 ..< 20:
        if not fileExists("/proc/" & $childPid):
          stopped = true
          break
        sleep(100)
      check stopped

    test "terminates when stdio reaches EOF":
      let root = currentSourcePath().parentDir.parentDir.parentDir
      let command = quoteShell(root / "onim") & " --stdio < /dev/null"
      let process = startProcess(
        "/bin/sh", args = ["-c", command], workingDir = root, options = {poUsePath}
      )
      defer:
        try:
          process.kill()
        except CatchableError:
          discard
        close process
      check process.waitForExit(2000) == 0
