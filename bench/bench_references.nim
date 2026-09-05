import std/[algorithm, monotimes, strutils, times]

import onim/features/references
import onim/index/source_index
import onim/session/ids
import onim/session/workspace

const
  sampleCount = 31
  queriesPerSample = 100

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

let typicalText = sourceFor(2_000)
let typical = localSnapshot(typicalText)
discard measure("typical", typical, typicalText.find("value", 10))

let adversarialText = shadowedSource(200)
let adversarial = localSnapshot(adversarialText)
discard measure("shadowed", adversarial, adversarialText.find("value", 10))
