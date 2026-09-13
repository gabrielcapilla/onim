import std/[json, os, sequtils, strutils, tables, unittest]

import harness/fixture
import harness/render
import harness/source
import harness/workspace_fs
import onim/features/completion
import onim/features/completion_models
import onim/features/definition
import onim/features/definition_models
import onim/features/hover
import onim/features/inlay
import onim/features/organize
import onim/features/organize_edits
import onim/features/references
import onim/features/rename
import onim/features/signature
import onim/index/type_kinds
import onim/index/source_index
import onim/protocol/navigation
import onim/protocol/text_features
import onim/protocol/uris
import onim/semantic/native_diagnostics
import onim/syntax/tokens
import onim/stdlib/map
import onim/stdlib/map_runtime
import onim/session/ids
import onim/session/workspace

suite "fixture feature harness":
  test "creates conservative procedure snippets from validated signatures":
    check signatureCallSnippet(
      "parseJson", "proc parseJson(buffer: string; filename: string): JsonNode"
    ) == "parseJson(${1:buffer}, ${2:filename})$0"
    check signatureCallSnippet(
      "read", "proc read(values: seq[tuple[a: int, b: string]]; count: int): int"
    ) == "read(${1:values}, ${2:count})$0"
    check signatureCallSnippet("main", "proc main()") == "main()$0"
    check signatureCallSnippet(
      "writeLine", "proc writeLine(f: File; x: varargs[string, `$`])"
    ) == ""
    check signatureCallSnippet("broken", "proc broken(value: seq[int]") == ""
    check signatureCallSnippet(
      "flushFile", "proc flushFile(f: File)", signatureMemberCall
    ) == "flushFile()$0"

  test "completes locals at a marker and preserves the edit range":
    let fixture =
      parseFixture("proc show() =\n" & "  let localValue = 10\n" & "  echo loc<|>\n")
    let snapshot = fixtureSnapshot(fixture)
    let result = completeAt(
      initWorkspace(), snapshot, fixture.cursors[0].byteOffset, emptyStdlibMap()
    )
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["localValue"]
    check result.replaceStart == fixture.cursors[0].byteOffset - 3
    check result.replaceEnd == fixture.cursors[0].byteOffset
    check renderCompletion(result).contains("item label=localValue")

  test "completes types and conditions from marker positions":
    let typeFixture = parseFixture("proc show() =\n  var value: u<|>\n")
    let typeResult = completeAt(
      initWorkspace(),
      fixtureSnapshot(typeFixture),
      typeFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check typeResult.state == completionAvailable
    check typeResult.items.mapIt(it.label) ==
      @["uint", "uint16", "uint32", "uint64", "uint8"]

    let conditionFixture = parseFixture("when isMai<|>:\n  discard\n")
    let conditionResult = completeAt(
      initWorkspace(),
      fixtureSnapshot(conditionFixture),
      conditionFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check conditionResult.state == completionAvailable
    check conditionResult.items.mapIt(it.label) == @["isMainModule"]

  test "completes imported names and receiver members at markers":
    let importedFixture = parseFixture("import std/os\nwalkD<|>\n")
    let importedResult = completeAt(
      initWorkspace(),
      fixtureSnapshot(importedFixture),
      importedFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check importedResult.state == completionAvailable
    check importedResult.items.anyIt(it.label == "walkDir")

    let memberFixture = parseFixture("proc show() =\n  stdout.wri<|>\n")
    let memberResult = completeAt(
      initWorkspace(),
      fixtureSnapshot(memberFixture),
      memberFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check memberResult.state == completionAvailable
    check memberResult.items.anyIt(it.label == "writeLine")
    let writeLine = memberResult.items.filterIt(it.label == "writeLine")[0]
    check writeLine.detail.len > 0
    check writeLine.documentation.contains("Writes the values")

    let memberStartFixture = parseFixture("proc show() =\n" & "  stdout.<|>writeLine\n")
    let memberStartSource = memberStartFixture.files["main.nim"]
    let memberStart = memberStartSource.find("writeLine")
    let memberStartResult = completeAt(
      initWorkspace(),
      fixtureSnapshot(memberStartFixture),
      memberStartFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check memberStartResult.state == completionAvailable
    check memberStartResult.items.anyIt(it.label == "write")
    check memberStartResult.replaceStart == memberStart
    check memberStartResult.replaceEnd == memberStart + "writeLine".len

    let memberMiddleFixture =
      parseFixture("proc show() =\n" & "  stdout.wri<|>teLine\n")
    let memberMiddleSource = memberMiddleFixture.files["main.nim"]
    let memberMiddle = memberMiddleSource.find("writeLine")
    let memberMiddleResult = completeAt(
      initWorkspace(),
      fixtureSnapshot(memberMiddleFixture),
      memberMiddleFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check memberMiddleResult.state == completionAvailable
    check memberMiddleResult.items.anyIt(it.label == "write")
    check memberMiddleResult.replaceStart == memberMiddle
    check memberMiddleResult.replaceEnd == memberMiddle + "writeLine".len

  test "hovers a stdlib module at a marker":
    let fixture = parseFixture("import std/strf<|>ormat\n")
    let info = resolveHover(
      initWorkspace(),
      fixtureSnapshot(fixture),
      fixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check info.state == hoverAvailable
    check info.kind == "module"
    check info.module == "std/strformat"
    check info.documentation.len > 0

  test "hovers a documented stdlib symbol at a marker":
    let fixture = parseFixture("import std/os\nwalk<|>Dir(\"/tmp\")\n")
    let info = resolveHover(
      initWorkspace(),
      fixtureSnapshot(fixture),
      fixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check info.state == hoverAvailable
    check info.name == "walkDir"
    check info.module == "std/os"
    check info.documentation.len > 0

  test "renders an undeclared-name diagnostic at a marker":
    let fixture = parseFixture("proc show() =\n" & "  discard miss<|>ing\n")
    let diagnostics =
      nativeDiagnostics(indexSource(fixture.files["main.nim"]), loadStdlibMap(""))
    check diagnostics.len == 1
    check diagnostics[0].kind == nativeUndeclaredIdentifier
    check diagnostics[0].name == "missing"
    check diagnostics[0].startOffset == fixture.cursors[0].byteOffset - 4
    check renderDiagnostics(diagnostics).contains("kind=nativeUndeclaredIdentifier")

  test "hovers project docs, fields, and interpolation at markers":
    let docsFixture =
      parseFixture("## Greets the caller.\nproc greet*() = discard\n" & "gre<|>et()\n")
    let docsWorkspace = initWorkspace()
    let docsInfo = resolveHover(
      docsWorkspace,
      docsWorkspace.fixtureWorkspaceSnapshot(docsFixture, "/tmp/onim-feature-docs"),
      docsFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check docsInfo.state == hoverAvailable
    check docsInfo.documentation.contains("Greets the caller")

    let fieldFixture = parseFixture(
      "type Person = object\n  name*: string\n" &
        "proc show(person: Person) = discard person.na<|>me\n"
    )
    let fieldWorkspace = initWorkspace()
    let fieldInfo = resolveHover(
      fieldWorkspace,
      fieldWorkspace.fixtureWorkspaceSnapshot(fieldFixture, "/tmp/onim-feature-fields"),
      fieldFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check fieldInfo.state == hoverAvailable
    check fieldInfo.name == "name"
    check fieldInfo.kind == "field"

    let interpolationFixture = parseFixture(
      "let number = 190_000\n" & "proc show() = discard fmt\"{num<|>ber}\"\n"
    )
    let interpolationWorkspace = initWorkspace()
    let interpolationInfo = resolveHover(
      interpolationWorkspace,
      interpolationWorkspace.fixtureWorkspaceSnapshot(
        interpolationFixture, "/tmp/onim-feature-interpolation"
      ),
      interpolationFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check interpolationInfo.state == hoverAvailable
    check interpolationInfo.name == "number"
    check interpolationInfo.declarationLine == 1

    let literalFixture =
      parseFixture("proc show() =\n" & "  let byteValue = 99'u8\n" & "  byt<|>eValue\n")
    let literalWorkspace = initWorkspace()
    let literalInfo = resolveHover(
      literalWorkspace,
      literalWorkspace.fixtureWorkspaceSnapshot(
        literalFixture, "/tmp/onim-feature-literal"
      ),
      literalFixture.cursors[0].byteOffset,
      stdlibMap(),
    )
    check literalInfo.state == hoverAvailable
    check literalInfo.signature == "let byteValue: uint8"

  test "defers imported signature help until workspace bootstrap":
    let root = getTempDir() / ("onim-feature-signature-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-feature-signature-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let consumerText = "import provider\n  discard provider.add(1, \"\")\n"
    writeFile(providerPath, "proc add*(left: int, right: string): bool = true\n")
    writeFile(consumerPath, consumerText)
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let workspace = initWorkspace(root)
    let consumerUri = fileUri(consumerPath)
    discard workspace.openDocument(consumerUri, consumerPath, consumerText, 1)
    let params =
      %*{"textDocument": {"uri": consumerUri}, "position": {"line": 1, "character": 25}}
    let cold = signatureHelpResponse(params, workspace, emptyStdlibMap())
    check cold.value.kind == JNull
    check cold.needsBootstrap
    check workspace.bootstrapWorkspace()
    let warm = signatureHelpResponse(params, workspace, emptyStdlibMap())
    check not warm.needsBootstrap
    check warm.value["signatures"].len == 1
    check warm.value["signatures"][0]["label"].getStr.contains(
      "proc add*(left: int, right: string): bool"
    )
    check warm.value["signatures"][0]["parameters"].len == 2
    check warm.value["activeParameter"].getInt == 1

  test "defers document links until workspace bootstrap":
    let root = getTempDir() / ("onim-feature-links-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-feature-links-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    let providerPath = root / "provider.nim"
    let consumerPath = root / "consumer.nim"
    let consumerText = "import provider\n"
    writeFile(providerPath, "proc answer*() = discard\n")
    writeFile(consumerPath, consumerText)
    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")
      cleanTree(root)
      cleanTree(cacheRoot)

    let workspace = initWorkspace(root)
    let consumerUri = fileUri(consumerPath)
    discard workspace.openDocument(consumerUri, consumerPath, consumerText, 1)
    let params = %*{"textDocument": {"uri": consumerUri}}
    let cold = documentLinks(params, workspace)
    check cold.value.kind == JArray
    check cold.value.len == 0
    check cold.needsBootstrap
    check workspace.bootstrapWorkspace()
    let warm = documentLinks(params, workspace)
    check not warm.needsBootstrap
    check warm.value.len == 1
    check warm.value[0]["range"]["start"]["line"].getInt == 0
    check warm.value[0]["range"]["start"]["character"].getInt == 7
    check warm.value[0]["range"]["end"]["character"].getInt == 15
    check warm.value[0]["target"].getStr == fileUri(providerPath)

  test "completes indexed object fields at a marker":
    let fixture = parseFixture(
      "type Person = object\n" & "  name*: string\n" &
        "proc show(person: Person) = discard person.na<|>\n"
    )
    let workspace = initWorkspace()
    let snapshot =
      workspace.fixtureWorkspaceSnapshot(fixture, "/tmp/onim-feature-object")
    let result =
      completeAt(workspace, snapshot, fixture.cursors[0].byteOffset, emptyStdlibMap())
    check result.state == completionAvailable
    check result.items.mapIt(it.label) == @["name"]
    check result.replaceStart == fixture.cursors[0].byteOffset - 2
    check result.replaceEnd == fixture.cursors[0].byteOffset

  test "completes UFCS members from module-level values":
    let fixture = parseFixture(
      "let annotated: int = 2\n" & "let inferred = 3\n" &
        "proc scaleInt(value: int): int = discard\n" &
        "proc scaleByte(value: uint8): int = discard\n" & "proc show() =\n" &
        "  annotated.sc<|>\n" & "  inferred.sc<|>\n"
    )
    let snapshot = fixtureSnapshot(fixture)
    let workspace = initWorkspace()
    let annotated =
      completeAt(workspace, snapshot, fixture.cursors[0].byteOffset, emptyStdlibMap())
    let inferred =
      completeAt(workspace, snapshot, fixture.cursors[1].byteOffset, emptyStdlibMap())
    check annotated.state == completionAvailable
    check annotated.items.mapIt(it.label) == @["scaleInt"]
    check annotated.replaceEnd > annotated.replaceStart
    check inferred.state == completionAvailable
    check inferred.items.mapIt(it.label) == @["scaleByte"]
    check inferred.replaceEnd > inferred.replaceStart

  test "organizes imports from a marker fixture":
    let fixture = parseFixture(
      "import std/strformat\n" & "proc show() =\n" &
        "  for kind, path in walkDir(\"/tmp\"):\n" & "    discard kin<|>d\n"
    )
    let source = fixture.files["main.nim"]
    let edits = organizeSourceWithIndex("main.nim", source, indexSource(source))
    check fixture.cursors[0].byteOffset > 0
    check applyEdits(source, edits) ==
      "import std/os\n\nproc show() =\n  for kind, path in walkDir(\"/tmp\"):\n" &
      "    discard kind\n"

  test "resolves definitions and local references at markers":
    let definitionFixture = parseFixture("proc greet*() = discard\n" & "gre<|>et()\n")
    let definitionSnapshot = fixtureSnapshot(definitionFixture)
    let definitionToken = tokenAtOffset(
      definitionSnapshot.index.parsed.tokens, definitionFixture.cursors[0].byteOffset
    )
    let definition =
      resolveDefinitionAtToken(initWorkspace(), definitionSnapshot, definitionToken)
    check definition.kind == definitionResolved
    check renderDefinition(definition).contains("state=definitionResolved")

    let referencesFixture =
      parseFixture("proc show(value: int) =\n" & "  echo val<|>ue\n")
    let referencesSnapshot = fixtureSnapshot(referencesFixture)
    let references = resolveSameFileReferences(
      initWorkspace(),
      referencesSnapshot,
      referencesFixture.cursors[0].byteOffset,
      includeDeclaration = true,
    )
    check references.supported
    check references.tokens.len == 2

  test "inferred inlay hints use the marker-backed declaration":
    let fixture = parseFixture(
      "proc show() =\n" & "  let byt<|>eValue = 99'u8\n" & "  discard byteValue\n"
    )
    let workspace = initWorkspace()
    let snapshot =
      workspace.fixtureWorkspaceSnapshot(fixture, "/tmp/onim-feature-inlay")
    let hints = inferredInlayHints(workspace, snapshot, 0, snapshot.text.len)
    check hints.len == 1
    check hints[0].declarationToken < uint32(snapshot.index.parsed.tokens.len)
    check hints[0].typeResolution.info.kind == typeUInt8

  test "marker inlays cover module strings and local numeric values":
    let fixture = parseFixture(
      "let wor<|>d = \"World\"\n" & "proc show() =\n" & "  let num<|>ber = 99\n" &
        "  echo word & $number\n"
    )
    let workspace = initWorkspace()
    let snapshot =
      workspace.fixtureWorkspaceSnapshot(fixture, "/tmp/onim-feature-inlay-forms")
    let hints = inferredInlayHints(workspace, snapshot, 0, snapshot.text.len)
    check hints.len == 2
    check hints.anyIt(it.typeResolution.info.kind == typeString)
    check hints.anyIt(it.typeResolution.info.kind == typeUInt8)

  test "marker inlays resolve local procedure return values":
    let fixture = parseFixture(
      "proc name(): string = \"World\"\n" & "proc show() =\n" &
        "  let greeting<|> = name()\n" & "  echo greeting\n"
    )
    let workspace = initWorkspace()
    let snapshot =
      workspace.fixtureWorkspaceSnapshot(fixture, "/tmp/onim-feature-inlay-call")
    let hints = inferredInlayHints(workspace, snapshot, 0, snapshot.text.len)
    check hints.len == 1
    check hints[0].typeResolution.info.kind == typeString

  test "renames a marker-selected local binding":
    let fixture = parseFixture(
      "proc show(value: int) =\n" & "  let dou<|>bled = value\n" & "  echo doubled\n"
    )
    let workspace = initWorkspace()
    let snapshot =
      workspace.fixtureWorkspaceSnapshot(fixture, "/tmp/onim-feature-rename")
    let rename =
      resolveRename(workspace, snapshot, fixture.cursors[0].byteOffset, "scaled")
    check rename.state == renameAvailable
    check rename.matches.len == 2

  test "uses markers for project completion, definition, and references":
    let fixture = parseFixture(
      "//- provider.nim\n" & "proc answer*() = discard\n" &
        "proc scale*(value: int): int = discard\n" & "proc private() = discard\n" &
        "//- consumer.nim\n" & "import provider\n" & "provider.an<|>\n" &
        "provider.ans<|>wer()\n" & "proc show(value: int) =\n  value.sc<|>\n"
    )
    let root = getTempDir() / ("onim-feature-project-" & $getCurrentProcessId())
    let cacheRoot =
      getTempDir() / ("onim-feature-project-cache-" & $getCurrentProcessId())
    cleanTree(root)
    cleanTree(cacheRoot)
    createDir(root)
    defer:
      cleanTree(root)
      cleanTree(cacheRoot)

    for path, text in fixture.files:
      writeFile(root / path, text)

    let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
    putEnv("ONIM_CACHE_DIR", cacheRoot)
    defer:
      if previousCacheRoot.len > 0:
        putEnv("ONIM_CACHE_DIR", previousCacheRoot)
      else:
        delEnv("ONIM_CACHE_DIR")

    let workspace = initWorkspace(root)
    workspace.indexWorkspace()
    check workspace.graphComplete
    let providerId = workspace.fileIdForPath(root / "provider.nim")
    let consumerId = workspace.fileIdForPath(root / "consumer.nim")
    check providerId.valid and consumerId.valid
    let snapshot = workspace.snapshotForFile(consumerId)
    let completionCursor = fixture.cursors[0]
    let symbolCursor = fixture.cursors[1]
    let ufcsCursor = fixture.cursors[2]
    check completionCursor.file == "consumer.nim"
    check snapshot.text == fixture.files["consumer.nim"]
    check workspace.dependencies(consumerId).len == 1
    let stdlib = stdlibMap()

    let completion =
      completeAt(workspace, snapshot, completionCursor.byteOffset, stdlib)
    check completion.state == completionAvailable
    check completion.items.mapIt(it.label) == @["answer"]
    check completion.replaceStart == completionCursor.byteOffset - 2
    check completion.replaceEnd == completionCursor.byteOffset

    let ufcs = completeAt(workspace, snapshot, ufcsCursor.byteOffset, stdlib)
    check ufcs.state == completionAvailable
    check ufcs.items.mapIt(it.label) == @["scale"]
    check ufcs.replaceStart == ufcsCursor.byteOffset - 2
    check ufcs.replaceEnd == ufcsCursor.byteOffset

    let token = tokenAtOffset(snapshot.index.parsed.tokens, symbolCursor.byteOffset)
    let definition = resolveDefinitionAtToken(workspace, snapshot, token)
    check definition.kind == definitionResolved
    check definition.target.fileId.value == providerId.value

    let references =
      resolveReferences(workspace, snapshot, symbolCursor.byteOffset, true)
    check references.supported
    check references.target.fileId.value == providerId.value
    check references.matches.len == 2
