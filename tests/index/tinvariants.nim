import std/[os, strutils, unittest]

import onim/index/occurrences
import onim/index/scopes
import onim/index/scope_validation
import onim/index/source_index
import onim/index/type_ids
import onim/syntax/tokens

proc replaceAt(source, name, replacement: string): string =
  let start = source.rfind(name)
  doAssert start >= 0
  result = source[0 ..< start] & replacement
  let past = start + name.len
  if past < source.len:
    result.add source[past .. ^1]

proc insertAt(source: string, position: int, value: string): string =
  if position > 0:
    result.add source[0 ..< position]
  result.add value
  if position < source.len:
    result.add source[position .. ^1]

proc nextMutation(seed: var uint32): uint32 =
  seed = seed * 1664525'u32 + 1013904223'u32
  seed

proc mutationTrialCount(): int =
  let raw = getEnv("ONIM_INVARIANT_TRIALS")
  if raw.len == 0:
    return 64
  try:
    max(64, min(parseInt(raw), 100_000))
  except ValueError:
    64

proc indexMismatch(left, right: SourceIndex): string
proc indexesMatch(left, right: SourceIndex): bool {.inline.}

type Mutation = object
  position: int
  value: string

proc applyMutation(source: string, mutation: Mutation): string =
  insertAt(source, min(max(mutation.position, 0), source.len), mutation.value)

proc minimizeSequence[T](
    values: seq[T], fails: proc(candidate: seq[T]): bool {.closure.}
): seq[T] =
  result = values
  if result.len < 2 or not fails(result):
    return
  var partitions = 2
  while result.len >= 2:
    let chunkSize = max(1, (result.len + partitions - 1) div partitions)
    var reduced = false
    var first = 0
    while first < result.len:
      let past = min(result.len, first + chunkSize)
      var candidate: seq[T] = @[]
      for index in 0 ..< result.len:
        if index < first or index >= past:
          candidate.add result[index]
      if candidate.len > 0 and fails(candidate):
        result = candidate
        partitions = max(2, partitions - 1)
        reduced = true
        break
      first = past
    if not reduced:
      if partitions >= result.len:
        break
      partitions = min(result.len, partitions * 2)

proc mutationSequenceFails(initial: string, mutations: seq[Mutation]): bool =
  var source = initial
  var index = indexSource(source)
  for mutation in mutations:
    let edited = applyMutation(source, mutation)
    let incremental = tryIndexSourceIncremental(source, index, edited)
    let fresh = indexSource(edited)
    if incremental != nil and not indexesMatch(incremental, fresh):
      return true
    source = edited
    index = if incremental == nil: fresh else: incremental

proc renderMutationSequence(mutations: seq[Mutation]): string =
  for index, mutation in mutations:
    if index > 0:
      result.add ","
    result.add $mutation.position & ":" & mutation.value.replace("\n", "\\n")

proc indexMismatch(left, right: SourceIndex): string =
  if left == nil or right == nil:
    return "missing index"
  if left.contentHash != right.contentHash:
    return "content hash"
  if left.byteLength != right.byteLength:
    return "byte length"
  if left.tokenCount != right.tokenCount:
    return "token count"
  if left.parsed.tokens != right.parsed.tokens:
    return "tokens"
  if left.parsed.imports != right.parsed.imports:
    return "imports"
  if left.symbols != right.symbols:
    return "symbols"
  if left.scopes != right.scopes:
    return "scopes"
  if left.types != right.types:
    return "types"
  if left.occurrences != right.occurrences:
    return "occurrences"
  if left.imports != right.imports:
    return "import references"
  if left.exports != right.exports:
    return "export references"
  if left.includes != right.includes:
    return "include references"
  if not left.scopes.validateScopes(left.parsed.tokens, left.symbols, left.byteLength):
    return "scope validation"
  if not left.occurrences.validateOccurrences(left.parsed.tokens):
    return "occurrence validation"

proc indexesMatch(left, right: SourceIndex): bool {.inline.} =
  indexMismatch(left, right).len == 0

proc checkEquivalent(left, right: SourceIndex) =
  let mismatch = indexMismatch(left, right)
  if mismatch.len > 0:
    raise newException(AssertionDefect, "index mismatch: " & mismatch)

suite "native index invariants":
  test "incremental identifier edits equal fresh indexes":
    var source = "let value = 1\necho value\n"
    var index = indexSource(source)
    var name = "value"
    for replacement in ["alpha", "omega", "delta", "sigma"]:
      let edited = replaceAt(source, name, replacement)
      let incremental = tryIndexSourceIncremental(source, index, edited)
      let fresh = indexSource(edited)
      check incremental != nil
      checkEquivalent(incremental, fresh)
      source = edited
      index = incremental
      name = replacement

  test "bounded structural edits preserve the fresh-index fallback":
    var source = "let value = 1\necho value\n"
    var index = indexSource(source)
    let edits = [
      (needle: "value", replacement: "alpha"),
      (needle: "alpha", replacement: "alphaName"),
      (needle: "alphaName", replacement: "a"),
      (needle: "echo", replacement: "echo("),
    ]
    for edit in edits:
      let edited = replaceAt(source, edit.needle, edit.replacement)
      let incremental = tryIndexSourceIncremental(source, index, edited)
      let fresh = indexSource(edited)
      check fresh != nil
      check fresh.scopes.validateScopes(
        fresh.parsed.tokens, fresh.symbols, fresh.byteLength
      )
      check fresh.occurrences.validateOccurrences(fresh.parsed.tokens)
      if incremental != nil:
        checkEquivalent(incremental, fresh)
      source = edited
      index = fresh

  test "seeded edits preserve incremental equivalence":
    const mutationTokens = [" ", "\n", "a", "_", "(", ")", "\"", "0'u8"]
    let seedValue = 0x4F4E494D'u32
    var seed = seedValue
    var source = "proc show(value: int) =\n  let number = 99'u8\n  echo value\n"
    var index = indexSource(source)
    let initial = source
    var mutations: seq[Mutation] = @[]
    let trialCount = mutationTrialCount()
    for trial in 0 ..< trialCount:
      let state = nextMutation(seed)
      let position = int(state mod uint32(source.len + 1))
      let mutation = mutationTokens[int((state shr 8) mod uint32(mutationTokens.len))]
      let mutationRecord = Mutation(position: position, value: mutation)
      let edited = applyMutation(source, mutationRecord)
      let incremental = tryIndexSourceIncremental(source, index, edited)
      let fresh = indexSource(edited)
      mutations.add mutationRecord
      if incremental != nil:
        let mismatch = indexMismatch(incremental, fresh)
        if mismatch.len > 0:
          let minimal = minimizeSequence(
            mutations,
            proc(candidate: seq[Mutation]): bool =
              mutationSequenceFails(initial, candidate),
          )
          raise newException(
            AssertionDefect,
            "incremental index mismatch (" & mismatch & ") seed=" & $seedValue &
              " trial=" & $trial & " minimal=" & renderMutationSequence(minimal),
          )
      source = edited
      index = if incremental == nil: fresh else: incremental

  test "minimizes a deterministic mutation failure":
    let values = @[1, 2, 3, 4, 5]
    let minimal = minimizeSequence(
      values,
      proc(candidate: seq[int]): bool =
        candidate.len >= 2 and candidate[0] == 1 and candidate[^1] == 5,
    )
    check minimal == @[1, 5]

  test "malformed editing buffers remain indexable":
    for source in [
      "`", "```", "\"\"\"", "proc (]) =", "when when when", "type A = object of",
      "let value = (1 +", "let n = 99'u8", "let n = 190_000", "echo `name`",
      "let emoji = \"😀\"", "\x00let value = 1", "\xFF\xFE",
    ]:
      try:
        check indexSource(source) != nil
      except CatchableError as error:
        echo "indexing raised for malformed input: ", error.msg
        check false
