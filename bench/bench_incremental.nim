import std/[algorithm, monotimes, strutils, times]

import onim/index/source_index

const
  sampleCount = 201
  lineCounts = [100, 1800, 10000]

proc sourceFor(lineCount: int): string =
  result = "let base = 1\n"
  for _ in 1 ..< lineCount:
    result.add "echo base\n"

proc replacementAt(source: string, lineCount, position: int): string =
  let targetOccurrence = 1 + ((lineCount - 2) * position div 2)
  let target = "echo base"
  var offset = 0
  for _ in 0 ..< targetOccurrence:
    offset = source.find(target, offset) + target.len
  let nameStart = offset - 4
  source[0 ..< nameStart] & "data" & source[offset .. ^1]

proc percentile(values: var seq[float], rank: float): float =
  values.sort
  let index = min(values.high, int(float(values.len - 1) * rank))
  values[index]

for lineCount in lineCounts:
  let oldSource = sourceFor(lineCount)
  let oldIndex = indexSource(oldSource)
  var baseline: seq[float] = @[]
  var incremental: seq[float] = @[]
  var fallbackCount = 0
  var fallbackByPosition = [0, 0, 0]
  var checksum = 0

  for sample in 0 ..< sampleCount:
    let position = sample mod 3
    let newSource = replacementAt(oldSource, lineCount, position)

    let baselineStarted = getMonoTime()
    let rebuilt = indexSource(newSource)
    baseline.add (getMonoTime() - baselineStarted).inNanoseconds.float / 1_000_000
    inc checksum, rebuilt.tokenCount

    let incrementalStarted = getMonoTime()
    let updated = tryIndexSourceIncremental(oldSource, oldIndex, newSource)
    incremental.add (getMonoTime() - incrementalStarted).inNanoseconds.float / 1_000_000
    if updated == nil:
      inc fallbackCount
      inc fallbackByPosition[position]
    else:
      inc checksum, updated.tokenCount

  echo "lines=",
    lineCount,
    " samples=",
    sampleCount,
    " fallback=",
    fallbackCount,
    " fallback_by_position=",
    fallbackByPosition,
    " baseline_median_ms=",
    baseline.percentile(0.50),
    " baseline_p95_ms=",
    baseline.percentile(0.95),
    " baseline_p99_ms=",
    baseline.percentile(0.99),
    " incremental_median_ms=",
    incremental.percentile(0.50),
    " incremental_p95_ms=",
    incremental.percentile(0.95),
    " incremental_p99_ms=",
    incremental.percentile(0.99),
    " checksum=",
    checksum
