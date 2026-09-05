import std/[algorithm, json, monotimes, osproc, streams, strutils, times]
import std/os except FileId

import onim/features/references
import onim/index/source_index
import onim/session/ids
import onim/session/workspace

const
  sampleCount = 31
  queriesPerSample = 100
  projectQueriesPerSample = 20
  generatedModuleCount = 1024

proc percentile(values: var seq[float], rank: float): float =
  values.sort
  let index = min(values.high, int(float(values.len - 1) * rank))
  values[index]

proc median(values: seq[float]): float =
  var ordered = values
  ordered.percentile(0.5)

proc localSnapshot(text: string): WorkspaceSnapshot =
  result.valid = true
  result.id = SnapshotId(1)
  result.fileId = FileId(1)
  result.text = text
  result.contentGeneration = ContentGeneration(1)
  result.index = indexSource(text)

proc sourceFor(useCount: int): string =
  result = "proc measure(value: int) =\n"
  for _ in 0 ..< useCount:
    result.add "  echo value\n"

proc shadowedSource(routineCount: int): string =
  for routineIndex in 0 ..< routineCount:
    result.add "proc routine" & $routineIndex & "(value: int) =\n"
    result.add "  echo value\n"

proc measure(name: string, snapshot: WorkspaceSnapshot, offset: int): seq[float] =
  let workspace = initWorkspace()
  for _ in 0 ..< 10:
    let warm =
      resolveSameFileReferences(workspace, snapshot, offset, includeDeclaration = false)
    doAssert warm.supported and warm.tokens.len > 0
  for _ in 0 ..< sampleCount:
    let started = getMonoTime()
    var checksum = 0
    for _ in 0 ..< queriesPerSample:
      let references = resolveSameFileReferences(
        workspace, snapshot, offset, includeDeclaration = false
      )
      doAssert references.supported and references.tokens.len > 0
      inc checksum, references.tokens.len
    doAssert checksum > 0
    result.add (getMonoTime() - started).inNanoseconds.float /
      (1_000_000 * queriesPerSample)
  let middle = result.median()
  let upper = result.percentile(0.95)
  var deviations: seq[float] = @[]
  for sample in result:
    deviations.add abs(sample - middle)
  echo name,
    " samples=",
    sampleCount,
    " queries=",
    queriesPerSample,
    " median_us=",
    middle * 1_000,
    " p95_us=",
    upper * 1_000,
    " mad_us=",
    deviations.median() * 1_000

type ProjectCase = object
  workspace: Workspace
  root: string
  targetId: FileId
  queryId: FileId
  snapshot: WorkspaceSnapshot
  offset: int
  candidateCount: int
  expectedMatches: int

proc cleanTree(root: string) =
  if not dirExists(root):
    return
  var directories: seq[string] = @[]
  for path in walkDirRec(root):
    if fileExists(path):
      removeFile(path)
    elif dirExists(path):
      directories.add path
  directories.sort(
    proc(left, right: string): int =
      cmp(right.len, left.len)
  )
  for path in directories:
    if dirExists(path):
      removeDir(path)
  if dirExists(root):
    removeDir(root)

proc moduleName(index: int): string {.inline.} =
  "module_" & $index

proc dependentSource(
    target: string, index, usesPerDependent: int, falsePositive: bool
): string =
  result = "import " & target & "\n"
  if falsePositive and index == 1:
    for routineIndex in 0 ..< 200:
      result.add "proc local" & $routineIndex & "(answer: int) =\n"
      result.add "  echo answer\n"
  result.add "proc use" & $index & "() =\n"
  for _ in 0 ..< usesPerDependent:
    result.add "  " & target & ".answer()\n"

proc generateProject(
    root: string,
    moduleCount, dependentCount, usesPerDependent: int,
    falsePositive = false,
) =
  createDir(root)
  writeFile(root / (moduleName(0) & ".nim"), "proc answer*() = discard\n")
  for index in 1 ..< moduleCount:
    let path = root / (moduleName(index) & ".nim")
    if index <= dependentCount:
      writeFile(
        path, dependentSource(moduleName(0), index, usesPerDependent, falsePositive)
      )
    else:
      writeFile(path, "proc filler" & $index & "*() = discard\n")

proc projectForWorkspace(
    root: string, workspace: Workspace, dependentCount, usesPerDependent: int
): ProjectCase =
  result.root = root
  result.workspace = workspace
  result.targetId = result.workspace.fileIdForPath(root / "module_0.nim")
  result.queryId = result.workspace.fileIdForPath(root / "module_1.nim")
  result.snapshot = result.workspace.snapshotForFile(result.queryId)
  result.offset = result.snapshot.text.rfind("answer")
  result.candidateCount = result.workspace.dependents(result.targetId).len
  result.expectedMatches = dependentCount * usesPerDependent + 1

proc initializeProject(
    root: string, dependentCount, usesPerDependent: int
): ProjectCase =
  let workspace = initWorkspace(root)
  workspace.indexWorkspace()
  result = projectForWorkspace(root, workspace, dependentCount, usesPerDependent)

proc runProjectQuery(project: ProjectCase): tuple[success: bool, count: int] =
  let references = resolveReferences(
    project.workspace, project.snapshot, project.offset, includeDeclaration = true
  )
  result.count = references.matches.len
  result.success = references.supported and result.count == project.expectedMatches

proc measureProject(name: string, project: ProjectCase) =
  for _ in 0 ..< 5:
    let warm = project.runProjectQuery()
    doAssert warm.success
  var samples: seq[float] = @[]
  var failures = 0
  var checksum = 0
  for _ in 0 ..< sampleCount:
    let started = getMonoTime()
    for _ in 0 ..< projectQueriesPerSample:
      let value = project.runProjectQuery()
      if not value.success:
        inc failures
      checksum += value.count
    samples.add (getMonoTime() - started).inNanoseconds.float /
      (1_000_000 * projectQueriesPerSample)
  let middle = samples.median()
  let upper = samples.percentile(0.95)
  var deviations: seq[float] = @[]
  for sample in samples:
    deviations.add abs(sample - middle)
  echo name,
    " samples=",
    sampleCount,
    " queries=",
    projectQueriesPerSample,
    " median_us=",
    middle * 1_000,
    " p95_us=",
    upper * 1_000,
    " mad_us=",
    deviations.median() * 1_000,
    " results=",
    project.expectedMatches,
    " candidates=",
    project.candidateCount,
    " failures=",
    failures,
    " checksum=",
    checksum

proc measureIndex(name: string, workspace: Workspace): float =
  let started = getMonoTime()
  workspace.indexWorkspace()
  result = (getMonoTime() - started).inNanoseconds.float / 1_000_000
  echo name, " index_ms=", result

proc sendLspMessage(input: Stream, message: JsonNode) =
  let body = $message
  input.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  input.flush

proc readLspMessage(output: Stream): JsonNode =
  var contentLength = -1
  var line = ""
  while output.readLine(line):
    if line.len == 0:
      break
    let separator = line.find(':')
    if separator >= 0 and line[0 ..< separator].toLowerAscii == "content-length":
      contentLength = parseInt(line[separator + 1 .. ^1].strip)
  if contentLength < 0:
    return
  parseJson(output.readStr(contentLength))

proc readLspResponse(output: Stream, id: int): JsonNode =
  while true:
    let message = readLspMessage(output)
    if message == nil:
      return
    if message.hasKey("id") and message["id"].kind == JInt and message["id"].getInt == id:
      return message

proc measureStdio(name: string, project: ProjectCase) =
  let configuredServer = getEnv("ONIM_BIN")
  let server =
    if configuredServer.len > 0:
      absolutePath(configuredServer)
    else:
      getCurrentDir() / "onim"
  if not fileExists(server):
    echo name, " unavailable=1 server=", server
    return

  let queryPath = project.root / "module_1.nim"
  let queryUri = "file://" & queryPath.replace('\\', '/')
  let queryText = readFile(queryPath)
  let process = startProcess(server, args = ["--stdio"], workingDir = project.root)
  defer:
    close process

  sendLspMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 1,
      "method": "initialize",
      "params": {"rootUri": "file://" & project.root.replace('\\', '/')},
    },
  )
  let initialized = readLspResponse(process.outputStream, 1)
  if initialized == nil:
    echo name, " failures=1 phase=initialize"
    return
  sendLspMessage(
    process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
  )
  sendLspMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument":
          {"uri": queryUri, "languageId": "nim", "version": 1, "text": queryText}
      },
    },
  )

  let bootstrapStarted = getMonoTime()
  sendLspMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 2,
      "method": "textDocument/references",
      "params": {
        "textDocument": {"uri": queryUri},
        "position": {"line": 2, "character": 11},
        "context": {"includeDeclaration": true},
      },
    },
  )
  let first = readLspResponse(process.outputStream, 2)
  let bootstrapMilliseconds =
    (getMonoTime() - bootstrapStarted).inNanoseconds.float / 1_000_000
  var bootstrapFailures = 0
  if first == nil or first["result"].kind != JArray or
      first["result"].len != project.expectedMatches:
    bootstrapFailures = 1
  echo name,
    " bootstrap_ms=",
    bootstrapMilliseconds,
    " results=",
    if first == nil or first["result"].kind != JArray:
      0
    else:
      first["result"].len,
    " candidates=",
    project.candidateCount,
    " failures=",
    bootstrapFailures

  var samples: seq[float] = @[]
  var failures = bootstrapFailures
  for warmup in 0 ..< 5:
    let id = 1_000 + warmup
    sendLspMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": id,
        "method": "textDocument/references",
        "params": {
          "textDocument": {"uri": queryUri},
          "position": {"line": 2, "character": 11},
          "context": {"includeDeclaration": true},
        },
      },
    )
    let response = readLspResponse(process.outputStream, id)
    if response == nil or response["result"].kind != JArray or
        response["result"].len != project.expectedMatches:
      inc failures
  for sample in 0 ..< sampleCount:
    let started = getMonoTime()
    for query in 0 ..< projectQueriesPerSample:
      let id = 10_000 + sample * projectQueriesPerSample + query
      sendLspMessage(
        process.inputStream,
        %*{
          "jsonrpc": "2.0",
          "id": id,
          "method": "textDocument/references",
          "params": {
            "textDocument": {"uri": queryUri},
            "position": {"line": 2, "character": 11},
            "context": {"includeDeclaration": true},
          },
        },
      )
      let response = readLspResponse(process.outputStream, id)
      if response == nil or response["result"].kind != JArray or
          response["result"].len != project.expectedMatches:
        inc failures
    samples.add (getMonoTime() - started).inNanoseconds.float /
      (1_000_000 * projectQueriesPerSample)
  let middle = samples.median()
  let upper = samples.percentile(0.95)
  var deviations: seq[float] = @[]
  for sample in samples:
    deviations.add abs(sample - middle)
  echo name,
    " samples=",
    sampleCount,
    " queries=",
    projectQueriesPerSample,
    " median_us=",
    middle * 1_000,
    " p95_us=",
    upper * 1_000,
    " mad_us=",
    deviations.median() * 1_000,
    " results=",
    project.expectedMatches,
    " candidates=",
    project.candidateCount,
    " failures=",
    failures
  sendLspMessage(
    process.inputStream,
    %*{"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": nil},
  )
  discard readLspResponse(process.outputStream, 3)
  sendLspMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})

let typicalText = sourceFor(2_000)
let typical = localSnapshot(typicalText)
discard measure("typical", typical, typicalText.find("value", 10))

let adversarialText = shadowedSource(200)
let adversarial = localSnapshot(adversarialText)
discard measure("shadowed", adversarial, adversarialText.find("value", 10))

block generatedReferenceBenchmarks:
  let root = getTempDir() / ("onim-reference-bench-" & $getCurrentProcessId())
  let cacheRoot =
    getTempDir() / ("onim-reference-bench-cache-" & $getCurrentProcessId())
  cleanTree(root)
  cleanTree(cacheRoot)
  let previousCacheRoot = getEnv("ONIM_CACHE_DIR")
  putEnv("ONIM_CACHE_DIR", cacheRoot)
  defer:
    if previousCacheRoot.len > 0:
      putEnv("ONIM_CACHE_DIR", previousCacheRoot)
    else:
      delEnv("ONIM_CACHE_DIR")
    cleanTree(root)
    cleanTree(cacheRoot)

  generateProject(root, generatedModuleCount, 16, 2)
  let coldWorkspace = initWorkspace(root)
  discard measureIndex("generated-1024-cold", coldWorkspace)
  let warmWorkspace = initWorkspace(root)
  discard measureIndex("generated-1024-warm", warmWorkspace)
  let fanout16 = projectForWorkspace(root, warmWorkspace, 16, 2)
  let firstStarted = getMonoTime()
  let first = fanout16.runProjectQuery()
  echo "generated-1024-first-after-restart_us=",
    (getMonoTime() - firstStarted).inNanoseconds.float / 1_000,
    " results=",
    first.count,
    " candidates=",
    fanout16.candidateCount,
    " failures=",
    if first.success: 0 else: 1
  measureProject("generated-1024-fanout-16", fanout16)
  measureStdio("generated-1024-stdio", fanout16)

  let overlayPath = root / "module_1.nim"
  let overlayText = fanout16.snapshot.text & "  module_0.answer()\n"
  discard
    warmWorkspace.changeDocument("file://" & overlayPath, overlayPath, overlayText, 2)
  var overlay = projectForWorkspace(root, warmWorkspace, 16, 2)
  overlay.expectedMatches = fanout16.expectedMatches + 1
  let overlayStarted = getMonoTime()
  let overlayResult = overlay.runProjectQuery()
  echo "generated-1024-overlay-next_us=",
    (getMonoTime() - overlayStarted).inNanoseconds.float / 1_000,
    " results=",
    overlayResult.count,
    " candidates=",
    overlay.candidateCount,
    " failures=",
    if overlayResult.success: 0 else: 1

  let falseRoot =
    getTempDir() / ("onim-reference-bench-false-" & $getCurrentProcessId())
  cleanTree(falseRoot)
  defer:
    cleanTree(falseRoot)
  generateProject(falseRoot, generatedModuleCount, 16, 2, falsePositive = true)
  let falsePositive = initializeProject(falseRoot, 16, 2)
  measureProject("generated-1024-false-positive", falsePositive)

  let fanoutRoot =
    getTempDir() / ("onim-reference-bench-fanout-" & $getCurrentProcessId())
  cleanTree(fanoutRoot)
  defer:
    cleanTree(fanoutRoot)
  generateProject(fanoutRoot, generatedModuleCount, 256, 1)
  let fanout256 = initializeProject(fanoutRoot, 256, 1)
  measureProject("generated-1024-fanout-256", fanout256)
