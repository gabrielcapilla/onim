import std/[algorithm, monotimes, os, times]

import onim/features/organize
import onim/index/source_index
import onim/stdlib/map

const
  warmupCount = 10
  sampleCount = 31
  organizationsPerSample = 100

type BenchmarkResult = object
  samples: seq[int64]
  checksum: uint64
  handled: uint32

proc measureNative(
    filePath, source: string, index: SourceIndex, stdlib: StdlibMap
): BenchmarkResult =
  for _ in 0 ..< warmupCount:
    for _ in 0 ..< organizationsPerSample:
      let attempt = tryOrganizeSourceWithIndex(filePath, source, index, stdlib)
      if attempt.handled:
        inc result.handled
      result.checksum += uint64(attempt.edits.len + 1)
  for _ in 0 ..< sampleCount:
    let started = getMonoTime()
    for _ in 0 ..< organizationsPerSample:
      let attempt = tryOrganizeSourceWithIndex(filePath, source, index, stdlib)
      if attempt.handled:
        inc result.handled
      result.checksum += uint64(attempt.edits.len + 1)
    result.samples.add (getMonoTime() - started).inNanoseconds

proc measureWarmCompiler(filePath, source: string): BenchmarkResult =
  for _ in 0 ..< warmupCount:
    for _ in 0 ..< organizationsPerSample:
      let edits = organizeSource(filePath, source)
      result.checksum += uint64(edits.len + 1)
  for _ in 0 ..< sampleCount:
    let started = getMonoTime()
    for _ in 0 ..< organizationsPerSample:
      let edits = organizeSource(filePath, source)
      result.checksum += uint64(edits.len + 1)
    result.samples.add (getMonoTime() - started).inNanoseconds

proc report(label: string, result: BenchmarkResult) =
  var samples = result.samples
  samples.sort
  let median = samples[samples.len div 2]
  let p95Index = min(samples.high, (samples.len * 95 + 99) div 100 - 1)
  let p95 = samples[p95Index]
  var deviations = newSeqOfCap[int64](samples.len)
  for sample in samples:
    deviations.add abs(sample - median)
  deviations.sort
  let mad = deviations[deviations.len div 2]
  let divisor = organizationsPerSample.float * 1_000
  echo label,
    " samples=",
    samples.len,
    " organizations=",
    organizationsPerSample,
    " median_us=",
    median.float / divisor,
    " p95_us=",
    p95.float / divisor,
    " mad_us=",
    mad.float / divisor,
    " handled=",
    result.handled,
    " checksum=",
    result.checksum

let root = currentSourcePath().parentDir.parentDir
let sourcePath = root / "tests" / "before" / "walkdir.nim"
let stdlib = loadStdlibMap("")

var source = "for k, v in walkDir(\"/tmp\"):\n  discard k\n"
for _ in 0 ..< 1798:
  source.add "discard 1\n"
let indexStarted = getMonoTime()
let index = indexSource(source)
let indexNs = (getMonoTime() - indexStarted).inNanoseconds
discard organizeSource(sourcePath, source)
report("native-missing-import", measureNative(sourcePath, source, index, stdlib))
echo "native-missing-import index_ms=", indexNs.float / 1_000_000

var aliasSource = "import std/os as file_system\n\nproc main() =\n"
aliasSource.add "  discard fileSystem.walkDir(\"/tmp\")\n"
for _ in 0 ..< 1795:
  aliasSource.add "  discard 1\n"
let aliasIndexStarted = getMonoTime()
let aliasIndex = indexSource(aliasSource)
let aliasIndexNs = (getMonoTime() - aliasIndexStarted).inNanoseconds
report("native-alias", measureNative(sourcePath, aliasSource, aliasIndex, stdlib))
echo "native-alias index_ms=", aliasIndexNs.float / 1_000_000

var compilerAliasSource = "when defined(posix):\n  import std/os as file_system\n\n"
compilerAliasSource.add "proc main() =\n  discard fileSystem.walkDir(\"/tmp\")\n"
for _ in 0 ..< 1795:
  compilerAliasSource.add "  discard 1\n"
discard organizeSource(sourcePath, compilerAliasSource)
report("warm-compiler-alias", measureWarmCompiler(sourcePath, compilerAliasSource))
