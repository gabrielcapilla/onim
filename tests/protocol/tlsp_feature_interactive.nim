import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio
import protocol/feature_session

proc runFeatureInteractive*(session: FeatureSession) =
  let process = session.process
  let definitionUri = session.definitionUri
  let completionUri = "file:///tmp/onim-completion.nim"
  let completionText =
    "proc show(value: int) =\n  let localValue = value\n  const constantValue = 1\n  echo 😀 loc\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": completionUri,
          "languageId": "nim",
          "version": 1,
          "text": completionText,
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 16,
      "method": "textDocument/completion",
      "params": {
        "textDocument": {"uri": completionUri}, "position": {"line": 3, "character": 13}
      },
    },
  )
  let completionResult = readResponse(process.outputStream, 16)
  check completionResult != nil
  check not completionResult["result"]["isIncomplete"].getBool
  var localCompletion: JsonNode
  for item in completionResult["result"]["items"].items:
    if item["label"].getStr == "localValue":
      localCompletion = item
  check localCompletion != nil
  check localCompletion["kind"].getInt == 6
  check localCompletion["textEdit"]["range"]["start"]["line"].getInt == 3
  check localCompletion["textEdit"]["range"]["start"]["character"].getInt == 10
  check localCompletion["textEdit"]["range"]["end"]["character"].getInt == 13

  let parameterUri = "file:///tmp/onim-semantic-parameter.nim"
  let parameterText =
    "proc show(amount: int) =\n  let local = amount\n  discard local\n  discard amount\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": parameterUri, "languageId": "nim", "version": 1, "text": parameterText
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 48,
      "method": "textDocument/semanticTokens/full",
      "params": {"textDocument": {"uri": parameterUri}},
    },
  )
  let parameterSemantic = readResponse(process.outputStream, 48)
  check parameterSemantic != nil
  let parameterData = parameterSemantic["result"]["data"]
  var line = 0
  var character = 0
  var parameterCount = 0
  var localVariableCount = 0
  for first in countup(0, parameterData.len - 1, 5):
    let deltaLine = parameterData[first].getInt
    let deltaStart = parameterData[first + 1].getInt
    if deltaLine == 0:
      character += deltaStart
    else:
      line += deltaLine
      character = deltaStart
    if parameterData[first + 3].getInt == 9:
      inc parameterCount
      check parameterData[first + 2].getInt == 6
      if line == 0:
        check character == 10
      elif line == 1:
        check character == 14
      else:
        check line == 3
        check character == 10
    elif parameterData[first + 3].getInt == 3:
      if (line == 1 and character == 6) or (line == 2 and character == 10):
        inc localVariableCount
  check parameterCount == 3
  check localVariableCount == 2

  let changedCompletionText =
    "proc show(value: int) =\n  let localValue = value\n  const constantValue = 1\n  echo con\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didChange",
      "params": {
        "textDocument": {"uri": completionUri, "version": 2},
        "contentChanges": [{"text": changedCompletionText}],
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 17,
      "method": "textDocument/completion",
      "params": {
        "textDocument": {"uri": completionUri}, "position": {"line": 3, "character": 10}
      },
    },
  )
  let changedCompletionResult = readResponse(process.outputStream, 17)
  check changedCompletionResult != nil
  var constantCompletion: JsonNode
  for item in changedCompletionResult["result"]["items"].items:
    if item["label"].getStr == "constantValue":
      constantCompletion = item
  check constantCompletion != nil
  check constantCompletion["kind"].getInt == 21

  let memberCompletionText =
    "type Person = object\n  name: string\n\nproc show(person: Person) =\n  person.nam\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didChange",
      "params": {
        "textDocument": {"uri": completionUri, "version": 3},
        "contentChanges": [{"text": memberCompletionText}],
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 18,
      "method": "textDocument/completion",
      "params": {
        "textDocument": {"uri": completionUri}, "position": {"line": 4, "character": 12}
      },
    },
  )
  let memberCompletionResult = readResponse(process.outputStream, 18)
  check memberCompletionResult != nil
  var nameCompletion: JsonNode
  for item in memberCompletionResult["result"]["items"].items:
    if item["label"].getStr == "name":
      nameCompletion = item
  check nameCompletion != nil
  check nameCompletion["textEdit"]["newText"].getStr == "name"
  check nameCompletion["textEdit"]["range"]["start"]["character"].getInt == 9
  check nameCompletion["textEdit"]["range"]["end"]["character"].getInt == 12

  let referencesUri = "file:///tmp/onim-references.nim"
  let referencesText = "proc sum(value: int) =\n  let doubled = value\n  echo doubled\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": referencesUri,
          "languageId": "nim",
          "version": 1,
          "text": referencesText,
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 11,
      "method": "textDocument/references",
      "params": {
        "textDocument": {"uri": referencesUri},
        "position": {"line": 1, "character": 16},
        "context": {"includeDeclaration": true},
      },
    },
  )
  let referencesResult = readResponse(process.outputStream, 11)
  check referencesResult != nil
  check referencesResult["result"].kind == JArray
  check referencesResult["result"].len == 2
  check referencesResult["result"][0]["range"]["start"]["line"].getInt == 0
  check referencesResult["result"][0]["range"]["start"]["character"].getInt == 9
  check referencesResult["result"][1]["range"]["start"]["line"].getInt == 1
  check referencesResult["result"][1]["range"]["start"]["character"].getInt == 16

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 12,
      "method": "textDocument/definition",
      "params": {
        "textDocument": {"uri": referencesUri}, "position": {"line": 1, "character": 16}
      },
    },
  )
  let localDefinition = readResponse(process.outputStream, 12)
  check localDefinition != nil
  check localDefinition["result"]["uri"].getStr == referencesUri
  check localDefinition["result"]["range"]["start"]["line"].getInt == 0
  check localDefinition["result"]["range"]["start"]["character"].getInt == 9

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 104,
      "method": "textDocument/prepareRename",
      "params": {
        "textDocument": {"uri": referencesUri}, "position": {"line": 1, "character": 16}
      },
    },
  )
  let preparedLocalRename = readResponse(process.outputStream, 104)
  check preparedLocalRename != nil
  check preparedLocalRename["result"]["start"]["line"].getInt == 1
  check preparedLocalRename["result"]["start"]["character"].getInt == 16
  check preparedLocalRename["result"]["end"]["line"].getInt == 1
  check preparedLocalRename["result"]["end"]["character"].getInt == 21

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 13,
      "method": "textDocument/hover",
      "params": {
        "textDocument": {"uri": definitionUri}, "position": {"line": 2, "character": 1}
      },
    },
  )
  let localHover = readResponse(process.outputStream, 13)
  check localHover != nil
  check localHover["result"]["contents"]["value"].getStr.contains("helper")

  let typedHoverUri = "file:///tmp/onim-typed-hover.nim"
  let typedHoverText = "proc show() =\n  let smile = \"😀\"\n  discard smile\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": typedHoverUri,
          "languageId": "nim",
          "version": 1,
          "text": typedHoverText,
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 19,
      "method": "textDocument/hover",
      "params": {
        "textDocument": {"uri": typedHoverUri}, "position": {"line": 1, "character": 7}
      },
    },
  )
  let typedLocalHover = readResponse(process.outputStream, 19)
  check typedLocalHover != nil
  let typedLocalHoverValue = typedLocalHover["result"]["contents"]["value"].getStr
  check typedLocalHoverValue.contains("```nim\nlet smile: string = \"😀\"\n```")
  check typedLocalHoverValue.contains("*Declared at line:* 2")
  check not typedLocalHoverValue.contains("let smile = \"😀\"")
  check not typedLocalHoverValue.contains("```nim\nlet smile: string\n```")

  let hoverUri = "file:///tmp/onim-hover.nim"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": hoverUri,
          "languageId": "nim",
          "version": 1,
          "text": "import std/os\nwalkDir(\"/tmp\")\n",
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 14,
      "method": "textDocument/hover",
      "params":
        {"textDocument": {"uri": hoverUri}, "position": {"line": 1, "character": 1}},
    },
  )
  let stdlibHover = readResponse(process.outputStream, 14)
  check stdlibHover != nil
  let stdlibHoverValue = stdlibHover["result"]["contents"]["value"].getStr
  check stdlibHoverValue.contains("*Module:* `std/os`")
  check stdlibHoverValue.contains("Walks over")
  check not stdlibHoverValue.contains("# std/os\n```")

  let stdlibModuleHoverUri = "file:///tmp/onim-stdlib-module-hover.nim"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": stdlibModuleHoverUri,
          "languageId": "nim",
          "version": 1,
          "text": "import std/strformat\n",
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 142,
      "method": "textDocument/hover",
      "params": {
        "textDocument": {"uri": stdlibModuleHoverUri},
        "position": {"line": 0, "character": 13},
      },
    },
  )
  let stdlibModuleHover = readResponse(process.outputStream, 142)
  check stdlibModuleHover != nil
  let stdlibModuleHoverValue = stdlibModuleHover["result"]["contents"]["value"].getStr
  check stdlibModuleHoverValue.contains("*Module:* `std/strformat`")
  check stdlibModuleHoverValue.len > 0

  let documentedHoverUri = "file:///tmp/onim-documented-hover.nim"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": documentedHoverUri,
          "languageId": "nim",
          "version": 1,
          "text":
            "proc main() =\n" & "  # Main function with a simple comment\n" &
            "  ## Main function with a docstring\n" & "  discard\n",
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 141,
      "method": "textDocument/hover",
      "params": {
        "textDocument": {"uri": documentedHoverUri},
        "position": {"line": 0, "character": 6},
      },
    },
  )
  let documentedHover = readResponse(process.outputStream, 141)
  check documentedHover != nil
  let documentedHoverValue = documentedHover["result"]["contents"]["value"].getStr
  check documentedHoverValue.contains("Main function with a simple comment")
  check documentedHoverValue.contains("Main function with a docstring")

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 15,
      "method": "textDocument/rename",
      "params": {
        "textDocument": {"uri": referencesUri},
        "position": {"line": 1, "character": 16},
        "newName": "scaled",
      },
    },
  )
  let renameResult = readResponse(process.outputStream, 15)
  check renameResult != nil
  check renameResult["result"]["changes"][referencesUri].kind == JArray
  check renameResult["result"]["changes"][referencesUri].len == 2
  check renameResult["result"]["changes"][referencesUri][0]["newText"].getStr == "scaled"
