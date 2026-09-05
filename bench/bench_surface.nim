import std/[algorithm, monotimes, times]

import onim/index/surfaces
import onim/index/symbols
import onim/session/ids as onimIds

const
  sampleCount = 31
  moduleCounts = [64, 256, 1024, 4096]

proc contributor(moduleIndex: int, generation: uint64): SurfaceContributor =
  SurfaceContributor(
    fileId: onimIds.FileId(uint32(moduleIndex + 1)),
    contentGeneration: onimIds.ContentGeneration(generation),
    input: SurfaceInput(
      module: "project/module" & $moduleIndex,
      origin: surfaceProject,
      exports: @[
        SurfaceExportInput(
          name: "value",
          kind: symbolProc,
          kindKnown: true,
          declaredArity: 0,
          shapeKnown: true,
        )
      ],
    ),
  )

proc percentile(values: var seq[float], rank: float): float =
  values.sort
  let index = min(values.high, int(float(values.len - 1) * rank))
  values[index]

for moduleCount in moduleCounts:
  var contributors = newSeqOfCap[SurfaceContributor](moduleCount)
  for moduleIndex in 0 ..< moduleCount:
    contributors.add contributor(moduleIndex, 1)

  let coldStarted = getMonoTime()
  var previous = buildProjectSurfaceIndex(contributors, universeComplete = true)
  let coldNanoseconds = (getMonoTime() - coldStarted).inNanoseconds
  var rebuilds: seq[float] = @[]
  var checksum = previous.bindingCount
  for sample in 0 ..< sampleCount:
    let moduleIndex = sample mod moduleCount
    contributors[moduleIndex] = contributor(moduleIndex, uint64(sample + 2))
    let started = getMonoTime()
    previous = buildProjectSurfaceIndex(
      contributors, universeComplete = true, previous = previous
    )
    rebuilds.add (getMonoTime() - started).inNanoseconds.float / 1_000_000
    inc checksum, previous.bindingCount

  echo "modules=",
    moduleCount,
    " samples=",
    sampleCount,
    " cold_ms=",
    coldNanoseconds.float / 1_000_000,
    " rebuild_median_ms=",
    rebuilds.percentile(0.50),
    " rebuild_p95_ms=",
    rebuilds.percentile(0.95),
    " checksum=",
    checksum
