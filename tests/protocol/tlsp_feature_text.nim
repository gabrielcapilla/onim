import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio
import protocol/feature_session

proc runFeatureText*(session: FeatureSession) =
  let process = session.process
  let definitionUri = session.definitionUri
  let highlightUri = "file:///tmp/onim-highlight.nim"
  let highlightText = "proc main() =\n  let value = 1\n  echo value\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": highlightUri, "languageId": "nim", "version": 1, "text": highlightText
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
  check inlays["result"][0]["label"].getStr == ": uint8"
  check inlays["result"][0]["kind"].getInt == 1
  check inlays["result"][0]["position"]["line"].getInt == 1
  check inlays["result"][0]["position"]["character"].getInt == 11

  let stringHintUri = "file:///tmp/onim-string-hint.nim"
  let stringHintText =
    "let word = \"text\"\nlet number = 99\nlet negative = -872048\n" &
    "let explicit: uint8 = 99\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": stringHintUri,
          "languageId": "nim",
          "version": 1,
          "text": stringHintText,
        }
      },
    },
  )
  check readDiagnostics(process.outputStream, stringHintUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 90,
      "method": "textDocument/inlayHint",
      "params": {
        "textDocument": {"uri": stringHintUri},
        "range":
          {"start": {"line": 0, "character": 0}, "end": {"line": 4, "character": 0}},
      },
    },
  )
  let stringInlays = readResponse(process.outputStream, 90)
  check stringInlays != nil
  check stringInlays["result"].kind == JArray
  check stringInlays["result"].len == 3
  check stringInlays["result"][0]["label"].getStr == ": string"
  check stringInlays["result"][0]["position"]["line"].getInt == 0
  check stringInlays["result"][0]["position"]["character"].getInt == 8
  check stringInlays["result"][0]["paddingLeft"].getBool == false
  check stringInlays["result"][1]["label"].getStr == ": uint8"
  check stringInlays["result"][1]["position"]["line"].getInt == 1
  check stringInlays["result"][1]["position"]["character"].getInt == 10
  check stringInlays["result"][2]["label"].getStr == ": int32"
  check stringInlays["result"][2]["position"]["line"].getInt == 2
  check stringInlays["result"][2]["position"]["character"].getInt == 12
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didClose",
      "params": {"textDocument": {"uri": stringHintUri}},
    },
  )

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 30,
      "method": "textDocument/documentHighlight",
      "params":
        {"textDocument": {"uri": highlightUri}, "position": {"line": 2, "character": 7}},
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
          "uri": signatureUri, "languageId": "nim", "version": 1, "text": signatureText
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
        "textDocument": {"uri": signatureUri}, "position": {"line": 2, "character": 17}
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
        "textDocument": {"uri": definitionUri}, "position": {"line": 1, "character": 5}
      },
    },
  )
  let declarationDefinition = readResponse(process.outputStream, 8)
  check declarationDefinition != nil
  check declarationDefinition["result"]["range"]["start"]["line"].getInt == 1
  check declarationDefinition["result"]["range"]["start"]["character"].getInt == 5
