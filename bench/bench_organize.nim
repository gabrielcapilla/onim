import std/[algorithm, monotimes, os, times]

import onim/features/organize

const samplePrefix = "for k, v in walkDir(\"/tmp\"):\n  discard k\n"

let root = currentSourcePath().parentDir.parentDir
let sourcePath = root / "tests" / "before" / "walkdir.nim"
var source = samplePrefix
for _ in 0 ..< 1798:
  source.add "discard 1\n"

# Prime the embedded compiler and bundled symbol map before collecting samples.
discard organizeSource(sourcePath, source)

var samples: seq[int64] = @[]
for _ in 0 ..< 10:
  let started = getMonoTime()
  discard organizeSource(sourcePath, source)
  samples.add (getMonoTime() - started).inNanoseconds
samples.sort

let median = samples[samples.len div 2].float / 1_000_000
let p95 =
  samples[min(samples.len - 1, (samples.len * 95 + 99) div 100 - 1)].float / 1_000_000
echo "lines=1800 samples=", samples.len, " median_ms=", median, " p95_ms=", p95
