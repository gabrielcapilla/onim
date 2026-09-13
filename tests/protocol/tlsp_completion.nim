import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio

suite "stdio LSP completion":
  test "returns native field completion with UTF-16 ranges":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
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
    check not completion["result"]["isIncomplete"].getBool
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

  test "uses insert and replace ranges for a cursor before a member token":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let uri = "file:///tmp/onim-member-insert-replace.nim"
    let source = "proc main() =\n  stdout.writeLine\n"
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 151,
        "method": "initialize",
        "params": {
          "rootUri": "file://" & projectRoot.replace('\\', '/'),
          "capabilities": {
            "textDocument": {
              "completion": {
                "completionItem": {"insertReplaceSupport": true, "snippetSupport": true}
              }
            }
          },
        },
      },
    )
    check readResponse(process.outputStream, 151) != nil
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
    discard readDiagnostics(process.outputStream, uri)
    let cursor = "  stdout.".len
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 152,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": cursor}},
      },
    )
    let completion = readResponse(process.outputStream, 152)
    check completion != nil
    var writeLineItem: JsonNode
    for item in completion["result"]["items"]:
      if item["label"].getStr == "writeLine":
        writeLineItem = item
    check writeLineItem != nil
    let edit = writeLineItem["textEdit"]
    check edit.hasKey("insert")
    check edit.hasKey("replace")
    check not edit.hasKey("range")
    check edit["insert"]["start"]["character"].getInt == cursor
    check edit["insert"]["end"]["character"].getInt == cursor
    check edit["replace"]["start"]["character"].getInt == cursor
    check edit["replace"]["end"]["character"].getInt == cursor + "writeLine".len
    check not writeLineItem.hasKey("insertTextFormat")
    check edit["newText"].getStr == "writeLine"
    var flushFileItem: JsonNode
    for item in completion["result"]["items"]:
      if item["label"].getStr == "flushFile":
        flushFileItem = item
    check flushFileItem != nil
    check flushFileItem["insertTextFormat"].getInt == 2
    check flushFileItem["textEdit"]["newText"].getStr == "flushFile()$0"

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 153, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 153)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "uses the replacement range when insert-replace edits are unsupported":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let uri = "file:///tmp/onim-member-insert-range.nim"
    let source = "proc main() =\n  stdout.writeLine\n"
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 161,
        "method": "initialize",
        "params": {"rootUri": "file://" & projectRoot.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 161) != nil
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
    discard readDiagnostics(process.outputStream, uri)
    let cursor = "  stdout.".len
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 162,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": cursor}},
      },
    )
    let completion = readResponse(process.outputStream, 162)
    check completion != nil
    var writeLineItem: JsonNode
    for item in completion["result"]["items"]:
      if item["label"].getStr == "writeLine":
        writeLineItem = item
    check writeLineItem != nil
    let edit = writeLineItem["textEdit"]
    check edit.hasKey("range")
    check not edit.hasKey("insert")
    check not edit.hasKey("replace")
    check edit["range"]["start"]["character"].getInt == cursor
    check edit["range"]["end"]["character"].getInt == cursor + "writeLine".len

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 163, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 163)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "replays incomplete completion contexts through stdio":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let uri = "file:///tmp/onim-editor-flow.nim"
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 201,
        "method": "initialize",
        "params": {"rootUri": "file://" & projectRoot.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 201) != nil
    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
    )

    let condition = "when "
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
          "textDocument":
            {"uri": uri, "languageId": "nim", "version": 1, "text": condition}
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 202,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 5}},
      },
    )
    let conditionResult = readResponse(process.outputStream, 202)
    check conditionResult != nil
    var hasMainModule = false
    for item in conditionResult["result"]["items"]:
      hasMainModule = hasMainModule or item["label"].getStr == "isMainModule"
    check hasMainModule
    check conditionResult["result"]["items"][0]["textEdit"]["range"]["start"][
      "character"
    ].getInt == 5
    check conditionResult["result"]["items"][0]["textEdit"]["range"]["end"]["character"].getInt ==
      5

    let emptyType = "proc main() =\n  var value: "
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 2},
          "contentChanges": [{"text": emptyType}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 203,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 13}},
      },
    )
    let emptyTypeResult = readResponse(process.outputStream, 203)
    check emptyTypeResult != nil
    var emptyHasInt = false
    var emptyHasString = false
    for item in emptyTypeResult["result"]["items"]:
      emptyHasInt = emptyHasInt or item["label"].getStr == "int"
      emptyHasString = emptyHasString or item["label"].getStr == "string"
    check emptyHasInt
    check emptyHasString
    check emptyTypeResult["result"]["items"][0]["textEdit"]["range"]["start"][
      "character"
    ].getInt == 13
    check emptyTypeResult["result"]["items"][0]["textEdit"]["range"]["end"]["character"].getInt ==
      13

    let typedType = "proc main() =\n  var value: u"
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 3},
          "contentChanges": [{"text": typedType}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 204,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 14}},
      },
    )
    let typedTypeResult = readResponse(process.outputStream, 204)
    check typedTypeResult != nil
    check typedTypeResult["result"]["items"].len == 5
    var typedHasUint8 = false
    for item in typedTypeResult["result"]["items"]:
      typedHasUint8 = typedHasUint8 or item["label"].getStr == "uint8"
    check typedHasUint8
    check typedTypeResult["result"]["items"][0]["textEdit"]["range"]["start"][
      "character"
    ].getInt == 13
    check typedTypeResult["result"]["items"][0]["textEdit"]["range"]["end"]["character"].getInt ==
      14

    let incomplete = typedType & "\nproc pending() ="
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
          "textDocument": {"uri": uri, "version": 4},
          "contentChanges": [{"text": incomplete}],
        },
      },
    )
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 205,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 14}},
      },
    )
    let incompleteResult = readResponse(process.outputStream, 205)
    check incompleteResult != nil
    var incompleteHasUint32 = false
    for item in incompleteResult["result"]["items"]:
      incompleteHasUint32 = incompleteHasUint32 or item["label"].getStr == "uint32"
    check incompleteHasUint32

    sendMessage(
      process.inputStream,
      %*{"jsonrpc": "2.0", "id": 206, "method": "shutdown", "params": nil},
    )
    check readResponse(process.outputStream, 206)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "completion auto-imports use the configured stdlib spelling":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let uri = "file:///tmp/onim-legacy-stdlib-completion.nim"
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 301,
        "method": "initialize",
        "params": {
          "rootUri": "file://" & projectRoot.replace('\\', '/'),
          "initializationOptions": {"useStdPrefix": false},
        },
      },
    )
    check readResponse(process.outputStream, 301) != nil
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
            "uri": uri,
            "languageId": "nim",
            "version": 1,
            "text": "proc main() =\n  par\n",
          }
        },
      },
    )
    discard readDiagnostics(process.outputStream, uri)
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 302,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 5}},
      },
    )
    let completion = readResponse(process.outputStream, 302)
    check completion != nil
    var parseJsonItem: JsonNode
    for item in completion["result"]["items"].items:
      if item["label"].getStr == "parseJson":
        parseJsonItem = item
    check parseJsonItem != nil
    check parseJsonItem["additionalTextEdits"].len == 1
    check parseJsonItem["additionalTextEdits"][0]["newText"].getStr == "import json\n\n"

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 303, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 303)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0

  test "completes declarations from the current module":
    let projectRoot = currentSourcePath().parentDir.parentDir.parentDir
    let uri = "file:///tmp/onim-current-module-completion.nim"
    let source = "proc main() =\n  discard\n\nma\n"
    let process =
      startProcess(projectRoot / "onim", args = ["--stdio"], workingDir = projectRoot)
    defer:
      close process

    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 401,
        "method": "initialize",
        "params": {"rootUri": "file://" & projectRoot.replace('\\', '/')},
      },
    )
    check readResponse(process.outputStream, 401) != nil
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
    discard readDiagnostics(process.outputStream, uri)
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": 402,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 3, "character": 2}},
      },
    )
    let completion = readResponse(process.outputStream, 402)
    check completion != nil
    var mainItem: JsonNode
    for item in completion["result"]["items"]:
      if item["label"].getStr == "main":
        mainItem = item
    check mainItem != nil
    check mainItem["kind"].getInt == 3
    check mainItem["textEdit"]["range"]["start"]["character"].getInt == 0
    check mainItem["textEdit"]["range"]["end"]["character"].getInt == 2
    check mainItem["textEdit"]["newText"].getStr == "main"

    sendMessage(
      process.inputStream, %*{"jsonrpc": "2.0", "id": 403, "method": "shutdown"}
    )
    check readResponse(process.outputStream, 403)["result"].kind == JNull
    sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
    check process.waitForExit(3000) == 0
