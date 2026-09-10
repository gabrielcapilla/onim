import std/[json, os, osproc, strutils]

import ../index/source_index
import ../session/paths

type
  NimToolchainState* = enum
    toolchainUnavailable
    toolchainReady

  NimToolchain* = object
    state*: NimToolchainState
    nimExe*: string
    libPath*: string
    version*: string
    key*: string

proc runToolchainCommand*(
    executable, workingDir: string, args: openArray[string]
): tuple[output: string, exitCode: int] =
  var command = quoteShell(executable)
  for argument in args:
    command.add " " & quoteShell(argument)
  try:
    execCmdEx(command, options = {poStdErrToStdOut, poUsePath}, workingDir = workingDir)
  except CatchableError:
    ("", -1)

proc jsonFromToolchainOutput*(output: string): JsonNode =
  let first = output.find('{')
  let last = output.rfind('}')
  if first < 0 or last <= first:
    return
  try:
    parseJson(output[first .. last])
  except CatchableError:
    nil

proc resolveNimToolchain*(workingDir: string): NimToolchain =
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    return
  let root =
    if workingDir.len > 0:
      canonicalPath(workingDir)
    else:
      getCurrentDir()
  let probe = getTempDir() / ("onim-toolchain-" & $getCurrentProcessId() & ".nim")
  try:
    writeFile(probe, "discard\n")
    let dump = runToolchainCommand(
      nimExe,
      root,
      ["dump", "--dump.format:json", "--hints:off", "--warnings:off", probe],
    )
    if dump.exitCode != 0:
      return
    let value = jsonFromToolchainOutput(dump.output)
    if value == nil or value.kind != JObject or not value.hasKey("libpath") or
        value["libpath"].kind != JString or not value.hasKey("version") or
        value["version"].kind != JString:
      return
    result.state = toolchainReady
    result.nimExe = canonicalPath(nimExe)
    result.libPath = canonicalPath(value["libpath"].getStr)
    result.version = value["version"].getStr
    if result.libPath.len == 0 or result.version.len == 0:
      result = NimToolchain()
      return
    result.key = $contentFingerprint(
      result.nimExe & "\n" & result.libPath & "\n" & result.version & "\n" & hostOS &
        "\n" & hostCPU
    )
  except CatchableError:
    result = NimToolchain()
  finally:
    if fileExists(probe):
      try:
        removeFile(probe)
      except CatchableError:
        discard
