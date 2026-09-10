import std/[atomics, json, monotimes, osproc, streams, times]
import std/os except FileId

import ../features/organize
import ../features/organize_edits
import ../session/ids

type
  SemanticWorkKind* = enum
    semanticOrganize
    semanticStop

  SemanticRequest* = object
    kind*: SemanticWorkKind
    fileId*: FileId
    path*: string
    source*: string
    contentGeneration*: ContentGeneration
    dependencyGeneration*: DependencyGeneration
    configGeneration*: ConfigGeneration
    surfaceGeneration*: SurfaceGeneration
    useStdPrefix*: bool

  SemanticResult* = object
    failed*: bool
    fileId*: FileId
    contentGeneration*: ContentGeneration
    dependencyGeneration*: DependencyGeneration
    configGeneration*: ConfigGeneration
    surfaceGeneration*: SurfaceGeneration
    useStdPrefix*: bool
    edits*: seq[ImportEdit]

type WorkerReadLine = proc(stream: Stream, line: var string): bool {.nimcall, gcsafe.}

var child: Process
var resultLines: Channel[string]
var reader: Thread[pointer]
var started = false
var semanticPending: Atomic[bool]

const semanticReceiveTimeoutMs = 30_000

proc traceSemanticWorker(event: string) {.inline.} =
  if getEnv("ONIM_TRACE_WORKERS").len > 0:
    stderr.writeLine("onim semantic worker: " & event)

proc readLineFromWorker(stream: Stream, line: var string): bool {.gcsafe.} =
  # Stream is owned by the child-process handle until the reader thread joins.
  # The compiler itself runs in the separate helper process.
  streams.readLine(stream, line)

proc readWorker(arg: pointer) {.thread.} =
  let stream = cast[Stream](arg)
  while true:
    var line = ""
    if not readLineFromWorker(stream, line):
      discard resultLines.trySend($(%*{"kind": "workerError"}))
      break
    # The embedded compiler can write informational diagnostics to stderr.
    # stderr is merged into this pipe so it cannot fill an unread descriptor;
    # only the worker's JSON object lines belong to the protocol.
    if line.len > 0 and line[0] == '{':
      resultLines.send line

proc workerInteger(node: JsonNode, name: string): int64 =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JInt:
    node[name].getInt
  else:
    0

proc workerString(node: JsonNode, name: string): string =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JString:
    result = node[name].getStr

proc decodeSemanticResult*(line: string): SemanticResult =
  try:
    let node = parseJson(line)
    if node.kind != JObject or not node.hasKey("kind") or node["kind"].kind != JString or
        node["kind"].getStr != "result":
      result.failed = true
      return
    result.fileId = FileId(uint32(workerInteger(node, "fileId")))
    result.contentGeneration =
      ContentGeneration(uint64(workerInteger(node, "contentGeneration")))
    result.dependencyGeneration =
      DependencyGeneration(uint64(workerInteger(node, "dependencyGeneration")))
    result.configGeneration =
      ConfigGeneration(uint64(workerInteger(node, "configGeneration")))
    result.surfaceGeneration =
      SurfaceGeneration(uint64(workerInteger(node, "surfaceGeneration")))
    result.useStdPrefix =
      node.hasKey("useStdPrefix") and node["useStdPrefix"].kind == JBool and
      node["useStdPrefix"].getBool
    if node.hasKey("failed") and node["failed"].kind == JBool and node["failed"].getBool:
      result.failed = true
      return
    if node.hasKey("edits") and node["edits"].kind == JArray:
      for item in node["edits"].items:
        if item.kind != JObject:
          continue
        result.edits.add ImportEdit(
          startOffset: int(workerInteger(item, "startOffset")),
          endOffset: int(workerInteger(item, "endOffset")),
          newText: workerString(item, "newText"),
        )
  except CatchableError:
    result.failed = true

proc encodeSemanticResult*(value: SemanticResult): string =
  var response = newJObject()
  response["kind"] = %"result"
  response["fileId"] = %int64(uint32(value.fileId))
  response["contentGeneration"] = %int64(uint64(value.contentGeneration))
  response["dependencyGeneration"] = %int64(uint64(value.dependencyGeneration))
  response["configGeneration"] = %int64(uint64(value.configGeneration))
  response["surfaceGeneration"] = %int64(uint64(value.surfaceGeneration))
  response["failed"] = %value.failed
  response["useStdPrefix"] = %value.useStdPrefix
  var responseEdits = newJArray()
  for edit in value.edits:
    responseEdits.add %*{
      "startOffset": edit.startOffset,
      "endOffset": edit.endOffset,
      "newText": edit.newText,
    }
  response["edits"] = responseEdits
  $response

proc sendWorker(node: JsonNode): bool =
  if not started or child == nil:
    return false
  try:
    let stream = child.inputStream
    stream.writeLine($node)
    stream.flush
    true
  except CatchableError:
    false

proc startSemanticWorker*(): bool =
  if started:
    return true
  child = nil
  var resultLinesOpened = false
  try:
    child = startProcess(
      getAppFilename(),
      args = ["--semantic-worker"],
      workingDir = getCurrentDir(),
      options = {poStdErrToStdOut, poUsePath},
    )
    if child == nil:
      return false
    resultLines.open(2)
    resultLinesOpened = true
    semanticPending.store(false, moRelaxed)
    createThread(reader, readWorker, cast[pointer](child.outputStream))
    started = true
    traceSemanticWorker("start")
    true
  except CatchableError:
    if child != nil:
      try:
        child.kill()
      except CatchableError:
        discard
      try:
        discard child.waitForExit()
      except CatchableError:
        discard
      try:
        child.close
      except CatchableError:
        discard
      child = nil
    if resultLinesOpened:
      resultLines.close()
      resultLines = default(Channel[string])
    started = false
    false

proc submitSemantic*(request: SemanticRequest): bool =
  if request.kind != semanticOrganize:
    return sendWorker(%*{"kind": "stop"})
  let sent = sendWorker(
    %*{
      "kind": "organize",
      "fileId": uint32(request.fileId),
      "path": request.path,
      "source": request.source,
      "contentGeneration": uint64(request.contentGeneration),
      "dependencyGeneration": uint64(request.dependencyGeneration),
      "configGeneration": uint64(request.configGeneration),
      "surfaceGeneration": uint64(request.surfaceGeneration),
      "useStdPrefix": request.useStdPrefix,
    }
  )
  if sent:
    semanticPending.store(true, moRelaxed)
  sent

proc interruptSemanticWorker*(): bool =
  if not started or child == nil:
    return false
  try:
    traceSemanticWorker("interrupt")
    child.kill()
    true
  except CatchableError:
    false

proc tryReceiveSemantic*(value: var SemanticResult): bool =
  if not started:
    return false
  let received = resultLines.tryRecv()
  if not received.dataAvailable:
    return false
  value = decodeSemanticResult(received.msg)
  true

proc receiveSemantic*(): SemanticResult =
  if not started:
    result.failed = true
    return
  if not semanticPending.load(moRelaxed):
    result = decodeSemanticResult(resultLines.recv())
    return
  let startedAt = getMonoTime()
  while true:
    let received = resultLines.tryRecv()
    if received.dataAvailable:
      semanticPending.store(false, moRelaxed)
      result = decodeSemanticResult(received.msg)
      return
    if (getMonoTime() - startedAt).inNanoseconds >=
        int64(semanticReceiveTimeoutMs) * 1_000_000:
      semanticPending.store(false, moRelaxed)
      result.failed = true
      return
    sleep(10)

proc stopSemanticWorker*() =
  if not started:
    return
  discard submitSemantic(SemanticRequest(kind: semanticStop))
  if child != nil:
    let exitCode = child.waitForExit(1_000)
    if exitCode < 0:
      child.kill()
      discard child.waitForExit()
  reader.joinThread()
  if child != nil:
    try:
      child.close
    except CatchableError:
      discard
  child = nil
  traceSemanticWorker("reap")

proc finishSemanticWorkerStop*() =
  if not started:
    return
  resultLines.close()
  resultLines = default(Channel[string])
  started = false
  traceSemanticWorker("stop")

proc runSemanticWorkerProcess*() =
  while true:
    var line = ""
    if not stdin.readLine(line):
      break
    var request: JsonNode
    try:
      request = parseJson(line)
    except CatchableError:
      continue
    if request.kind != JObject or not request.hasKey("kind"):
      continue
    let kind = workerString(request, "kind")
    if kind == "stop":
      break
    if kind != "organize":
      continue

    var edits: seq[ImportEdit] = @[]
    var failed = false
    try:
      edits = organizeSource(
        workerString(request, "path"),
        workerString(request, "source"),
        OrganizeOptions(
          useStdPrefix:
            request.hasKey("useStdPrefix") and request["useStdPrefix"].kind == JBool and
            request["useStdPrefix"].getBool
        ),
      )
    except CatchableError:
      failed = true

    let useStdPrefix =
      request.hasKey("useStdPrefix") and request["useStdPrefix"].kind == JBool and
      request["useStdPrefix"].getBool
    stdout.writeLine(
      encodeSemanticResult(
        SemanticResult(
          failed: failed,
          fileId: FileId(uint32(workerInteger(request, "fileId"))),
          contentGeneration:
            ContentGeneration(uint64(workerInteger(request, "contentGeneration"))),
          dependencyGeneration:
            DependencyGeneration(uint64(workerInteger(request, "dependencyGeneration"))),
          configGeneration:
            ConfigGeneration(uint64(workerInteger(request, "configGeneration"))),
          surfaceGeneration:
            SurfaceGeneration(uint64(workerInteger(request, "surfaceGeneration"))),
          useStdPrefix: useStdPrefix,
          edits: edits,
        )
      )
    )
    stdout.flushFile()
