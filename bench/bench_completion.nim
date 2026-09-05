import std/[algorithm, json, monotimes, os, osproc, streams, strutils, times]

import onim/features/completion
import onim/index/source_index
import onim/session/ids as onimIds
import onim/session/workspace

const
  warmupCount = 10
  sampleCount = 31
  queriesPerSample = 100
  lspQueryCount = 1_000

proc percentile(values: var seq[float], rank: float): float =
  values.sort
  let index = min(values.high, int(float(values.len - 1) * rank))
  values[index]

proc median(values: seq[float]): float =
  var ordered = values
  ordered.percentile(0.5)

proc localSnapshot(source: string): WorkspaceSnapshot =
  result.valid = true
  result.id = onimIds.SnapshotId(1)
  result.fileId = onimIds.FileId(1)
  result.text = source
  result.contentGeneration = onimIds.ContentGeneration(1)
  result.index = indexSource(source)

proc sourceFor(declarationCount: int): string =
  result = "proc measure(value: int) =\n"
  for declarationIndex in 0 ..< declarationCount:
    result.add "  let local" & $declarationIndex & " = value\n"
  result.add "  echo local\n"

proc nestedSource(depth: int): string =
  result = "proc measure(value: int) =\n"
  for level in 0 ..< depth:
    result.add " ".repeat(2 * (level + 1)) & "block:\n"
    result.add " ".repeat(2 * (level + 2)) & "let nested" & $level & " = value\n"
  result.add " ".repeat(2 * (depth + 1)) & "echo nested\n"

proc completionOffset(source: string, prefix: string): int =
  let start = source.rfind(prefix)
  start + prefix.len

proc measureFeature(
    label: string, snapshot: WorkspaceSnapshot, offset: int
): seq[float] =
  for _ in 0 ..< warmupCount:
    let warm = completeLocals(snapshot, offset)
    doAssert warm.state == completionAvailable
  for _ in 0 ..< sampleCount:
    let started = getMonoTime()
    var checksum = 0
    for _ in 0 ..< queriesPerSample:
      let completion = completeLocals(snapshot, offset)
      doAssert completion.state == completionAvailable
      inc checksum, completion.items.len
    result.add (getMonoTime() - started).inNanoseconds.float /
      (1_000_000 * queriesPerSample)
    doAssert checksum > 0
  let middle = result.median()
  let upper = result.percentile(0.95)
  echo label,
    " declarations=",
    snapshot.index.scopes.declarations.len,
    " samples=",
    sampleCount,
    " median_us=",
    middle * 1_000,
    " p95_us=",
    upper * 1_000

proc retainedMemory(snapshot: WorkspaceSnapshot, offset: int) =
  let before = getOccupiedMem()
  var checksum = 0
  for _ in 0 ..< 100_000:
    let completion = completeLocals(snapshot, offset)
    doAssert completion.state == completionAvailable
    inc checksum, completion.items.len
  let after = getOccupiedMem()
  echo "retained_memory_before=",
    before,
    " after=",
    after,
    " delta=",
    int64(after) - int64(before),
    " checksum=",
    checksum

proc sendMessage(input: Stream, message: JsonNode) =
  let body = $message
  input.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  input.flush

proc readMessage(output: Stream): JsonNode =
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
  try:
    parseJson(output.readStr(contentLength))
  except CatchableError:
    nil

proc readResponse(output: Stream, id: int): JsonNode =
  while true:
    let message = readMessage(output)
    if message == nil:
      return
    if message.hasKey("id") and message["id"].kind == JInt and message["id"].getInt == id:
      return message

proc measureLsp(source: string): bool =
  let executable = getCurrentDir() / "onim"
  if not fileExists(executable):
    echo "lsp_roundtrip=skipped (build ./onim first)"
    return
  let root = getCurrentDir()
  let path = root / "bench" / "completion_bench.nim"
  let uri = "file://" & path.replace('\\', '/')
  let process = startProcess(executable, args = ["--stdio"], workingDir = root)
  defer:
    close process

  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": 1,
      "method": "initialize",
      "params": {"rootUri": "file://" & root.replace('\\', '/')},
    },
  )
  doAssert readResponse(process.outputStream, 1) != nil
  sendMessage(
    process.inputStream, %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}
  )
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "method": "textDocument/didOpen",
      "params": {
        "textDocument": {"uri": uri, "languageId": "nim", "version": 1, "text": source}
      },
    },
  )

  let line = max(0, source.count('\n') - 1)
  let character = "  echo local".len
  let warmRequest = 10
  sendMessage(
    process.inputStream,
    %*{
      "jsonrpc": "2.0",
      "id": warmRequest,
      "method": "textDocument/completion",
      "params": {
        "textDocument": {"uri": uri}, "position": {"line": line, "character": character}
      },
    },
  )
  doAssert readResponse(process.outputStream, warmRequest) != nil

  let started = getMonoTime()
  var checksum = 0
  for requestIndex in 0 ..< lspQueryCount:
    let requestId = 100 + requestIndex
    sendMessage(
      process.inputStream,
      %*{
        "jsonrpc": "2.0",
        "id": requestId,
        "method": "textDocument/completion",
        "params": {
          "textDocument": {"uri": uri},
          "position": {"line": line, "character": character},
        },
      },
    )
    let response = readResponse(process.outputStream, requestId)
    doAssert response != nil
    inc checksum, response["result"]["items"].len
  let elapsed = (getMonoTime() - started).inNanoseconds.float / 1_000_000
  echo "lsp_roundtrip_queries=",
    lspQueryCount,
    " median_ms=",
    elapsed / lspQueryCount,
    " total_ms=",
    elapsed,
    " checksum=",
    checksum

  sendMessage(
    process.inputStream,
    %*{"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": nil},
  )
  doAssert readResponse(process.outputStream, 2) != nil
  sendMessage(process.inputStream, %*{"jsonrpc": "2.0", "method": "exit"})
  true

for declarationCount in [8, 64, 512]:
  let source = sourceFor(declarationCount)
  let snapshot = localSnapshot(source)
  discard measureFeature("locals", snapshot, source.completionOffset("local"))

for depth in [1, 8, 32]:
  let source = nestedSource(depth)
  let snapshot = localSnapshot(source)
  discard measureFeature("nested", snapshot, source.completionOffset("nested"))

let retainedSource = sourceFor(64)
let retainedSnapshot = localSnapshot(retainedSource)
retainedMemory(retainedSnapshot, retainedSource.completionOffset("local"))
discard measureLsp(sourceFor(8))
