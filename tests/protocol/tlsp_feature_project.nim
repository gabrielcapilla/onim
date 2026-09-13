import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio
import protocol/feature_session

proc runFeatureProject*(session: FeatureSession) =
  let root = session.root
  let filePath = session.filePath
  let uri = session.uri
  let process = session.process
  let definitionUri = session.definitionUri
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
      "params":
        {"textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 9}},
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
      "id": 7,
      "method": "textDocument/definition",
      "params": {
        "textDocument": {"uri": definitionUri}, "position": {"line": 99, "character": 0}
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
      "params":
        {"textDocument": {"uri": uri}, "context": {"only": ["source.organizeImports"]}},
    },
  )
  let changedActions = readResponse(process.outputStream, 5)
  check changedActions != nil
  check changedActions["result"].len == 1
  check changedActions["result"][0]["edit"]["changes"][uri][0]["newText"].getStr.contains(
    "import std/os"
  )
