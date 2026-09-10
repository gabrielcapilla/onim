import std/[os, osproc, streams, strutils]

when defined(linux):
  import std/posix

import ../protocol/process_lifetime
import ../session/paths
import ./cache_paths
import ./generator
import ./map
import ./toolchain

type StdlibGenerationState* = enum
  stdlibGenerationIdle
  stdlibGenerationRunning
  stdlibGenerationReady
  stdlibGenerationFailed

var worker: Process
var workerResults: Channel[string]
var workerReader: Thread[pointer]
var workerStarted = false
var workerResultsOpened = false
var workerRoot = ""

proc readWorker(arg: pointer) {.thread.} =
  let stream = cast[Stream](arg)
  var line = ""
  if streams.readLine(stream, line):
    discard workerResults.trySend(line)
  else:
    discard workerResults.trySend("failed")

proc startStdlibGeneration*(root: string, toolchain: NimToolchain): bool =
  let workingDir =
    if root.len > 0:
      root
    else:
      getCurrentDir()
  if workerStarted:
    return workerRoot == canonicalPath(workingDir)
  try:
    worker = startProcess(
      getAppFilename(),
      args = [
        "--stdlib-worker",
        "--root:" & workingDir,
        "--nim:" & toolchain.nimExe,
        "--lib:" & toolchain.libPath,
        "--version:" & toolchain.version,
        "--key:" & toolchain.key,
      ],
      workingDir = workingDir,
      options = {poStdErrToStdOut, poUsePath},
    )
    if worker == nil:
      return false
    workerResults.open(1)
    workerResultsOpened = true
    createThread(workerReader, readWorker, cast[pointer](worker.outputStream))
    workerStarted = true
    workerRoot = canonicalPath(workingDir)
    true
  except CatchableError:
    if worker != nil:
      try:
        worker.kill()
      except CatchableError:
        discard
      try:
        discard worker.waitForExit()
      except CatchableError:
        discard
      try:
        worker.close()
      except CatchableError:
        discard
      worker = nil
    if workerResultsOpened:
      workerResults.close()
      workerResults = default(Channel[string])
      workerResultsOpened = false
    false

proc finishWorker() =
  if not workerStarted:
    return
  workerReader.joinThread()
  if worker != nil:
    try:
      discard worker.waitForExit(1_000)
    except CatchableError:
      discard
    try:
      worker.close()
    except CatchableError:
      discard
  worker = nil
  workerRoot = ""
  if workerResultsOpened:
    workerResults.close()
    workerResults = default(Channel[string])
    workerResultsOpened = false
  workerStarted = false

proc readyPath(line: string): string =
  if line.startsWith("ready:") and line.len > "ready:".len:
    result = line["ready:".len .. ^1]

proc pollStdlibGeneration*(path: var string): StdlibGenerationState =
  if not workerStarted:
    return stdlibGenerationIdle
  let received = workerResults.tryRecv()
  if not received.dataAvailable:
    return stdlibGenerationRunning
  path = readyPath(received.msg)
  let ready = path.len > 0
  finishWorker()
  if ready: stdlibGenerationReady else: stdlibGenerationFailed

proc waitStdlibGeneration*(path: var string): StdlibGenerationState =
  if not workerStarted:
    return stdlibGenerationIdle
  path = readyPath(workerResults.recv())
  let ready = path.len > 0
  finishWorker()
  if ready: stdlibGenerationReady else: stdlibGenerationFailed

proc stopStdlibGeneration*() =
  if not workerStarted:
    return
  if worker != nil:
    when defined(linux):
      discard posix.killpg(posix.Pid(worker.processID), posix.SIGTERM)
    try:
      let exitCode = worker.waitForExit(1_000)
      if exitCode < 0:
        worker.kill()
        discard worker.waitForExit()
    except CatchableError:
      try:
        worker.kill()
      except CatchableError:
        discard
  finishWorker()

proc publishCache(toolchain: NimToolchain, temporaryBinary: string): bool =
  let binary = stdlibBinaryPath(toolchain)
  let manifest = stdlibManifestPath(toolchain)
  if binary.len == 0 or manifest.len == 0:
    return false
  if fileExists(binary):
    if validStdlibCache(toolchain) and loadStdlibBinary(binary).surfaceIsComplete:
      return true
    try:
      removeFile(binary)
    except CatchableError:
      discard
  try:
    moveFile(temporaryBinary, binary)
  except CatchableError:
    if not (fileExists(binary) and loadStdlibBinary(binary).surfaceIsComplete):
      return false

  let temporaryManifest = stdlibTemporaryPath(manifest, "")
  try:
    writeFile(temporaryManifest, stdlibManifest(toolchain))
    if fileExists(manifest):
      if readFile(manifest) == stdlibManifest(toolchain):
        removeFile(temporaryManifest)
      else:
        removeFile(manifest)
    if fileExists(temporaryManifest):
      moveFile(temporaryManifest, manifest)
    validStdlibCache(toolchain)
  except CatchableError:
    if fileExists(temporaryManifest):
      try:
        removeFile(temporaryManifest)
      except CatchableError:
        discard
    false

proc runStdlibWorkerProcess*(): bool =
  when defined(linux):
    bindToParentProcess()
    discard posix.setsid()
  var root = getCurrentDir()
  var toolchain = NimToolchain()
  for argument in commandLineParams():
    if argument.startsWith("--root:") and argument.len > "--root:".len:
      root = argument["--root:".len .. ^1]
    elif argument.startsWith("--nim:") and argument.len > "--nim:".len:
      toolchain.nimExe = argument["--nim:".len .. ^1]
    elif argument.startsWith("--lib:") and argument.len > "--lib:".len:
      toolchain.libPath = argument["--lib:".len .. ^1]
    elif argument.startsWith("--version:") and argument.len > "--version:".len:
      toolchain.version = argument["--version:".len .. ^1]
    elif argument.startsWith("--key:") and argument.len > "--key:".len:
      toolchain.key = argument["--key:".len .. ^1]
  if toolchain.nimExe.len > 0 and toolchain.libPath.len > 0 and toolchain.version.len > 0 and
      toolchain.key.len > 0:
    toolchain.state = toolchainReady
  if toolchain.state != toolchainReady:
    stdout.writeLine("failed")
    return false
  let binary = stdlibBinaryPath(toolchain)
  if validStdlibCache(toolchain) and loadStdlibBinary(binary).surfaceIsComplete:
    stdout.writeLine("ready:" & binary)
    return true
  let directory = stdlibCacheDirectory(toolchain)
  if directory.len == 0:
    stdout.writeLine("failed")
    return false
  try:
    createDir(directory)
  except CatchableError:
    stdout.writeLine("failed")
    return false
  let temporaryJson = stdlibTemporaryPath(binary, ".json")
  let temporaryBinary = changeFileExt(temporaryJson, "bin")
  defer:
    for path in [temporaryJson, temporaryBinary]:
      if fileExists(path):
        try:
          removeFile(path)
        except CatchableError:
          discard
  let generated = generateStdlibMap(
    GeneratorConfig(
      nimExe: toolchain.nimExe,
      libPath: toolchain.libPath,
      outputPath: temporaryJson,
      nimVersion: toolchain.version,
    )
  )
  if not generated or not fileExists(temporaryBinary) or
      not loadStdlibBinary(temporaryBinary).surfaceIsComplete:
    stdout.writeLine("failed")
    return false
  if not publishCache(toolchain, temporaryBinary):
    stdout.writeLine("failed")
    return false
  stdout.writeLine("ready:" & binary)
  true
