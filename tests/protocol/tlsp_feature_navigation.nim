import std/[json, os, osproc, streams, strutils, times, unittest]

import onim/stdlib/cache_paths
import onim/stdlib/toolchain
import harness/stdio
import protocol/feature_session

proc runFeatureNavigation*(session: FeatureSession) =
  let process = session.process
  let definitionUri = "file:///tmp/onim-definition.nim"
  let definitionText = "let smile = \"😀\"\nproc helper*() = discard\nhelper()\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": definitionUri,
          "languageId": "nim",
          "version": 1,
          "text": definitionText,
        }
      },
    },
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 10,
      "method": "textDocument/documentSymbol",
      "params": {"textDocument": {"uri": definitionUri}},
    },
  )
  let documentSymbols = readResponse(process.outputStream, 10)
  check documentSymbols != nil
  check documentSymbols["result"].kind == JArray
  check documentSymbols["result"].len == 2
  check documentSymbols["result"][0]["name"].getStr == "smile"
  check documentSymbols["result"][0]["kind"].getInt == 13
  check documentSymbols["result"][0]["selectionRange"]["start"]["line"].getInt == 0
  check documentSymbols["result"][0]["selectionRange"]["start"]["character"].getInt == 4
  check documentSymbols["result"][1]["name"].getStr == "helper"
  check documentSymbols["result"][1]["kind"].getInt == 12
  check documentSymbols["result"][1]["range"]["start"]["line"].getInt == 1

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 35,
      "method": "textDocument/semanticTokens/full",
      "params": {"textDocument": {"uri": definitionUri}},
    },
  )
  let semantic = readResponse(process.outputStream, 35)
  check semantic != nil
  let semanticData = semantic["result"]["data"]
  check semanticData.kind == JArray
  check semanticData.len >= 20
  check semanticData[0].getInt == 0
  check semanticData[1].getInt == 0
  check semanticData[2].getInt == 3
  check semanticData[3].getInt == 6
  check semanticData[4].getInt == 0
  check semanticData[5].getInt == 0
  check semanticData[6].getInt == 4
  check semanticData[7].getInt == 5
  check semanticData[8].getInt == 3
  check semanticData[9].getInt == 0
  check semanticData[45].getInt == 1
  check semanticData[46].getInt == 0
  check semanticData[47].getInt == 6
  check semanticData[48].getInt == 2

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 44,
      "method": "textDocument/semanticTokens/range",
      "params": {
        "textDocument": {"uri": definitionUri},
        "range":
          {"start": {"line": 1, "character": 1}, "end": {"line": 1, "character": 6}},
      },
    },
  )
  let semanticRange = readResponse(process.outputStream, 44)
  check semanticRange != nil
  let semanticRangeData = semanticRange["result"]["data"]
  check semanticRangeData.kind == JArray
  check semanticRangeData.len == 10
  check semanticRangeData[0].getInt == 1
  check semanticRangeData[1].getInt == 0
  check semanticRangeData[2].getInt == 4
  check semanticRangeData[3].getInt == 6
  check semanticRangeData[4].getInt == 0
  check semanticRangeData[5].getInt == 0
  check semanticRangeData[6].getInt == 5
  check semanticRangeData[7].getInt == 6
  check semanticRangeData[8].getInt == 2
  check semanticRangeData[9].getInt == 0

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 45,
      "method": "textDocument/semanticTokens/full",
      "params": {"textDocument": {"uri": definitionUri}},
    },
  )
  let semanticAgain = readResponse(process.outputStream, 45)
  check semanticAgain != nil
  check semanticAgain["result"]["data"] == semanticData

  let numericUri = "file:///tmp/onim-semantic-numeric.nim"
  let numericText = "let small = 99\nlet decimal = 3.14\nlet typed = 1'u8\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument":
          {"uri": numericUri, "languageId": "nim", "version": 1, "text": numericText}
      },
    },
  )
  check readDiagnostics(process.outputStream, numericUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 46,
      "method": "textDocument/semanticTokens/full",
      "params": {"textDocument": {"uri": numericUri}},
    },
  )
  let numericSemantic = readResponse(process.outputStream, 46)
  check numericSemantic != nil
  let numericData = numericSemantic["result"]["data"]
  check numericData.kind == JArray
  var line = 0
  var character = 0
  var numericCount = 0
  for first in countup(0, numericData.len - 1, 5):
    let deltaLine = numericData[first].getInt
    let deltaStart = numericData[first + 1].getInt
    if deltaLine == 0:
      character += deltaStart
    else:
      line += deltaLine
      character = deltaStart
    if numericData[first + 3].getInt == 8:
      inc numericCount
      if numericCount == 1:
        check line == 0
        check character == 12
        check numericData[first + 2].getInt == 2
      elif numericCount == 2:
        check line == 1
        check character == 14
        check numericData[first + 2].getInt == 4
      else:
        check line == 2
        check character == 12
        check numericData[first + 2].getInt == 4
  check numericData.len == 60
  check numericCount == 3
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 47,
      "method": "textDocument/semanticTokens/range",
      "params": {
        "textDocument": {"uri": numericUri},
        "range":
          {"start": {"line": 1, "character": 13}, "end": {"line": 1, "character": 18}},
      },
    },
  )
  let numericRange = readResponse(process.outputStream, 47)
  check numericRange != nil
  let numericRangeData = numericRange["result"]["data"]
  check numericRangeData.kind == JArray
  check numericRangeData.len == 5
  check numericRangeData[0].getInt == 1
  check numericRangeData[1].getInt == 14
  check numericRangeData[2].getInt == 4
  check numericRangeData[3].getInt == 8
  check numericRangeData[4].getInt == 0

  let memberUri = "file:///tmp/onim-semantic-member.nim"
  let memberText = "proc show() =\n  stdout.writeLine(\"x\")\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument":
          {"uri": memberUri, "languageId": "nim", "version": 1, "text": memberText}
      },
    },
  )
  check readDiagnostics(process.outputStream, memberUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 49,
      "method": "textDocument/semanticTokens/full",
      "params": {"textDocument": {"uri": memberUri}},
    },
  )
  let memberSemantic = readResponse(process.outputStream, 49)
  check memberSemantic != nil
  let memberData = memberSemantic["result"]["data"]
  var memberLine = 0
  var memberCharacter = 0
  var foundMethod = false
  for first in countup(0, memberData.len - 1, 5):
    let deltaLine = memberData[first].getInt
    let deltaStart = memberData[first + 1].getInt
    if deltaLine == 0:
      memberCharacter += deltaStart
    else:
      memberLine += deltaLine
      memberCharacter = deltaStart
    if memberData[first + 3].getInt == 10:
      check memberLine == 1
      check memberCharacter == 9
      check memberData[first + 2].getInt == 9
      foundMethod = true
  check foundMethod

  let typeUri = "file:///tmp/onim-semantic-type.nim"
  let typeText = "let word: string = \"x\"\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument":
          {"uri": typeUri, "languageId": "nim", "version": 1, "text": typeText}
      },
    },
  )
  check readDiagnostics(process.outputStream, typeUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 50,
      "method": "textDocument/semanticTokens/full",
      "params": {"textDocument": {"uri": typeUri}},
    },
  )
  let typeSemantic = readResponse(process.outputStream, 50)
  check typeSemantic != nil
  let typeData = typeSemantic["result"]["data"]
  var typeLine = 0
  var typeCharacter = 0
  var foundBuiltinType = false
  for first in countup(0, typeData.len - 1, 5):
    let deltaLine = typeData[first].getInt
    let deltaStart = typeData[first + 1].getInt
    if deltaLine == 0:
      typeCharacter += deltaStart
    else:
      typeLine += deltaLine
      typeCharacter = deltaStart
    if typeData[first + 3].getInt == 1:
      check typeLine == 0
      check typeCharacter == 10
      check typeData[first + 2].getInt == 6
      foundBuiltinType = true
  check foundBuiltinType

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 36,
      "method": "workspace/symbol",
      "params": {"query": "helper"},
    },
  )
  let workspaceSymbols = readResponse(process.outputStream, 36)
  check workspaceSymbols != nil
  check workspaceSymbols["result"].kind == JArray
  var foundHelper = false
  for item in workspaceSymbols["result"].items:
    if item["name"].getStr == "helper" and
        item["location"]["uri"].getStr == definitionUri:
      foundHelper = true
  check foundHelper
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 38,
      "method": "workspace/symbol",
      "params": {"query": "lp"},
    },
  )
  let substringSymbols = readResponse(process.outputStream, 38)
  check substringSymbols != nil
  var foundSubstring = false
  for item in substringSymbols["result"].items:
    if item["name"].getStr == "helper" and
        item["location"]["uri"].getStr == definitionUri:
      foundSubstring = true
  check foundSubstring

  let typeDefinitionUri = "file:///tmp/onim-type-definition.nim"
  let typeDefinitionText =
    "type Person = object\n  name: string\n\nproc show(person: ref Person) =\n  echo person.name\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": typeDefinitionUri,
          "languageId": "nim",
          "version": 1,
          "text": typeDefinitionText,
        }
      },
    },
  )
  check readDiagnostics(process.outputStream, typeDefinitionUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 37,
      "method": "textDocument/typeDefinition",
      "params": {
        "textDocument": {"uri": typeDefinitionUri},
        "position": {"line": 3, "character": 12},
      },
    },
  )
  let typeDefinition = readResponse(process.outputStream, 37)
  check typeDefinition != nil
  check typeDefinition["result"]["uri"].getStr == typeDefinitionUri
  check typeDefinition["result"]["range"]["start"]["line"].getInt == 0
  check typeDefinition["result"]["range"]["start"]["character"].getInt == 5

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 6,
      "method": "textDocument/definition",
      "params": {
        "textDocument": {"uri": definitionUri}, "position": {"line": 2, "character": 0}
      },
    },
  )
  let definitionResult = readResponse(process.outputStream, 6)
  check definitionResult != nil
  check definitionResult["result"]["uri"].getStr == definitionUri
  check definitionResult["result"]["range"]["start"]["line"].getInt == 1
  check definitionResult["result"]["range"]["start"]["character"].getInt == 5
  check definitionResult["result"]["range"]["end"]["character"].getInt == 11

  let implementationUri = "file:///tmp/onim-implementation.nim"
  let implementationText =
    "type Left = object\n" & "  value*: int\n" & "type Right = object\n" &
    "  value*: int\n" & "method render*(item: Left) = discard\n" &
    "method render*(item: Right) = discard\n" &
    "proc use(item: Left) = discard item.render()\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": implementationUri,
          "languageId": "nim",
          "version": 1,
          "text": implementationText,
        }
      },
    },
  )
  check readDiagnostics(process.outputStream, implementationUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 39,
      "method": "textDocument/implementation",
      "params": {
        "textDocument": {"uri": implementationUri},
        "position":
          {"line": 6, "character": implementationText.splitLines[6].find("render") + 1},
      },
    },
  )
  let implementations = readResponse(process.outputStream, 39)
  check implementations != nil
  check implementations["result"].kind == JArray
  check implementations["result"].len == 1
  check implementations["result"][0]["uri"].getStr == implementationUri
  check implementations["result"][0]["range"]["start"]["line"].getInt == 4
  check implementations["result"][0]["range"]["start"]["character"].getInt == 7

  let genericImplementationText =
    implementationText & "type Pair[A, B] = object\n" & "  first: A\n" & "  second: B\n" &
    "method render*(item: Pair[int, string]) = discard\n" &
    "method render*(item: Pair[int, bool]) = discard\n" &
    "proc usePair(item: Pair[int, string]) = discard item.render()\n" &
    "proc usePairBool(item: Pair[int, bool]) = discard item.render()\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didChange",
      "params": {
        "textDocument": {"uri": implementationUri, "version": 2},
        "contentChanges": [{"text": genericImplementationText}],
      },
    },
  )
  check readDiagnostics(process.outputStream, implementationUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 42,
      "method": "textDocument/implementation",
      "params": {
        "textDocument": {"uri": implementationUri},
        "position": {
          "line": 12,
          "character": genericImplementationText.splitLines[12].find("render") + 1,
        },
      },
    },
  )
  let genericImplementations = readResponse(process.outputStream, 42)
  check genericImplementations != nil
  check genericImplementations["result"].kind == JArray
  check genericImplementations["result"].len == 1
  check genericImplementations["result"][0]["uri"].getStr == implementationUri
  check genericImplementations["result"][0]["range"]["start"]["line"].getInt == 10
  check genericImplementations["result"][0]["range"]["start"]["character"].getInt == 7

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 43,
      "method": "textDocument/implementation",
      "params": {
        "textDocument": {"uri": implementationUri},
        "position": {
          "line": 13,
          "character": genericImplementationText.splitLines[13].find("render") + 1,
        },
      },
    },
  )
  let mismatchedGenericImplementations = readResponse(process.outputStream, 43)
  check mismatchedGenericImplementations != nil
  check mismatchedGenericImplementations["result"].kind == JArray
  check mismatchedGenericImplementations["result"].len == 1
  check mismatchedGenericImplementations["result"][0]["uri"].getStr == implementationUri
  check mismatchedGenericImplementations["result"][0]["range"]["start"]["line"].getInt ==
    11
  check mismatchedGenericImplementations["result"][0]["range"]["start"]["character"].getInt ==
    7

  let hierarchyUri = "file:///tmp/onim-hierarchy.nim"
  let hierarchyText = "proc leaf*() = discard\n" & "proc caller() =\n" & "  leaf()\n"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {
          "uri": hierarchyUri, "languageId": "nim", "version": 1, "text": hierarchyText
        }
      },
    },
  )
  check readDiagnostics(process.outputStream, hierarchyUri) != nil
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 40,
      "method": "textDocument/prepareCallHierarchy",
      "params": {
        "textDocument": {"uri": hierarchyUri},
        "position":
          {"line": 0, "character": hierarchyText.splitLines[0].find("leaf") + 1},
      },
    },
  )
  let leafItem = readResponse(process.outputStream, 40)
  check leafItem != nil
  check leafItem["result"].kind == JArray
  check leafItem["result"].len == 1
  check leafItem["result"][0]["name"].getStr == "leaf"
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 41,
      "method": "callHierarchy/incomingCalls",
      "params": {"item": leafItem["result"][0]},
    },
  )
  let incoming = readResponse(process.outputStream, 41)
  check incoming != nil
  check incoming["result"].kind == JArray
  check incoming["result"].len == 1
  check incoming["result"][0]["from"]["name"].getStr == "caller"
  check incoming["result"][0]["fromRanges"][0]["start"]["line"].getInt == 2
  check incoming["result"][0]["fromRanges"][0]["start"]["character"].getInt == 2
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 42,
      "method": "textDocument/prepareCallHierarchy",
      "params": {
        "textDocument": {"uri": hierarchyUri},
        "position":
          {"line": 1, "character": hierarchyText.splitLines[1].find("caller") + 1},
      },
    },
  )
  let callerItem = readResponse(process.outputStream, 42)
  check callerItem != nil
  check callerItem["result"].len == 1
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 43,
      "method": "callHierarchy/outgoingCalls",
      "params": {"item": callerItem["result"][0]},
    },
  )
  let outgoing = readResponse(process.outputStream, 43)
  check outgoing != nil
  check outgoing["result"].kind == JArray
  check outgoing["result"].len == 1
  check outgoing["result"][0]["to"]["name"].getStr == "leaf"
  check outgoing["result"][0]["fromRanges"][0]["start"]["line"].getInt == 2
  check outgoing["result"][0]["fromRanges"][0]["start"]["character"].getInt == 2
