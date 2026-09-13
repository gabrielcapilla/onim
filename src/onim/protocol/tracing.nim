import std/[json, monotimes, strutils, times]

import ../index/source_index
import ../session/ids
import ./semantic_key

type ProcessMemory = object
  residentKb: uint64
  peakResidentKb: uint64

proc processMemory(): ProcessMemory {.inline.} =
  when defined(linux):
    try:
      for line in readFile("/proc/self/status").splitLines:
        let fields = line.splitWhitespace
        if fields.len < 2:
          continue
        case fields[0]
        of "VmRSS:":
          result.residentKb = parseUInt(fields[1])
        of "VmHWM:":
          result.peakResidentKb = parseUInt(fields[1])
        else:
          discard
    except CatchableError:
      discard

proc traceLsp*(
    enabled: bool,
    event, uri: string,
    version: int64,
    snapshotId: SnapshotId,
    fileId: FileId,
    contentGeneration: ContentGeneration,
    dependencyGeneration: DependencyGeneration,
    reason, count: int,
) {.inline.} =
  if not enabled:
    return
  stderr.writeLine(
    "onim lsp event=" & event & " uriHash=" & $contentFingerprint(uri) & " version=" &
      $version & " snapshot=" & $uint64(snapshotId) & " file=" & $uint32(fileId) &
      " content=" & $uint64(contentGeneration) & " dependency=" &
      $uint64(dependencyGeneration) & " reason=" & $reason & " count=" & $count
  )

proc traceLspRequest*(
    enabled: bool,
    bridgeActive: bool,
    event: string,
    requestId: JsonNode,
    startedAt: MonoTime,
    key: SemanticKey,
    state: string,
) {.inline.} =
  if not enabled:
    return
  let requestHash =
    if requestId == nil:
      0'u64
    else:
      contentFingerprint($requestId)
  let durationNs = (getMonoTime() - startedAt).inNanoseconds
  let memory = processMemory()
  stderr.writeLine(
    "onim lsp request event=" & event & " requestHash=" & $requestHash & " durationNs=" &
      $durationNs & " state=" & state & " worker=" &
      (if bridgeActive: "active" else: "idle") & " file=" & $uint32(key.fileId) &
      " content=" & $uint64(key.contentGeneration) & " dependency=" &
      $uint64(key.dependencyGeneration) & " surface=" & $uint64(key.surfaceGeneration) &
      " rssKb=" & $memory.residentKb & " peakRssKb=" & $memory.peakResidentKb
  )
