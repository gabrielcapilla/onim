import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio
import protocol/feature_session

proc runFeatureOrganize*(session: FeatureSession) =
  let root = session.root
  let filePath = session.filePath
  let uri = session.uri
  let process = session.process
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 1,
      "method": "initialize",
      "params": {
        "rootUri": "file://" & root.replace('\\', '/'),
        "initializationOptions": {"useStdPrefix": true, "opinionatedHints": true},
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
  check initialized["result"]["capabilities"]["semanticTokensProvider"]["range"].getBool
  check initialized["result"]["capabilities"]["semanticTokensProvider"]["legend"][
    "tokenTypes"
  ].len == 11
  check initialized["result"]["capabilities"]["semanticTokensProvider"]["legend"][
    "tokenTypes"
  ][8].getStr == "number"
  check initialized["result"]["capabilities"]["semanticTokensProvider"]["legend"][
    "tokenTypes"
  ][9].getStr == "parameter"
  check initialized["result"]["capabilities"]["semanticTokensProvider"]["legend"][
    "tokenTypes"
  ][10].getStr == "method"
  check initialized["result"]["capabilities"]["workspaceSymbolProvider"].getBool
  check initialized["result"]["capabilities"]["inlayHintProvider"].getBool
  check not initialized["result"]["capabilities"]["completionProvider"][
    "resolveProvider"
  ].getBool
  check initialized["result"]["capabilities"]["completionProvider"]["triggerCharacters"][
    0
  ].getStr == "."
  check initialized["result"]["capabilities"]["completionProvider"]["triggerCharacters"][
    1
  ].getStr == "{"
  check initialized["result"]["capabilities"]["completionProvider"]["triggerCharacters"][
    2
  ].getStr == ":"
  check initialized["result"]["capabilities"]["completionProvider"]["triggerCharacters"][
    3
  ].getStr == " "

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

  let mainConditionalUri = "file:///tmp/onim-main-conditional.nim"
  let mainConditionalText =
    "when isMainModule:\n  for k, v in walkDir(\"/tmp\"):\n    discard v\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": mainConditionalUri,
          "languageId": "nim",
          "version": 1,
          "text": mainConditionalText,
        }
      },
    },
  )
  check readDiagnostics(process.outputStream, mainConditionalUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 91,
      "method": "textDocument/codeAction",
      "params": {
        "textDocument": {"uri": mainConditionalUri},
        "context": {"only": ["source.organizeImports"]},
      },
    },
  )
  let mainConditionalActions = readResponse(process.outputStream, 91)
  check mainConditionalActions != nil
  check mainConditionalActions["result"].len == 1
  check mainConditionalActions["result"][0]["edit"]["changes"][mainConditionalUri][0][
    "newText"
  ].getStr == "import std/os\n\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didClose",
      "params": {"textDocument": {"uri": mainConditionalUri}},
    },
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
  check aliasAction["result"][0]["edit"]["changes"][aliasUri][0]["newText"].getStr == ""
