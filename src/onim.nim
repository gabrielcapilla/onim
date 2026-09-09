when NimMajor < 2 or (NimMajor == 2 and NimMinor < 2):
  {.fatal: "onim requires Nim 2.2.0 or newer".}

import std/[os, osproc, strutils]

import onim/features/organize
import onim/features/organize_file
import onim/protocol/lsp
import onim/semantic/worker

const onimVersion = staticRead("../onim.nimble").split('"')[1]

proc usage(output: File) =
  output.writeLine "usage: onim [--stdio] [--useStdPrefix:on|off] | onim file.nim"
  output.writeLine "       onim --version"

proc version(output: File) =
  output.writeLine "onim " & onimVersion

proc formatNimFile(filePath: string): bool =
  let formatter = findExe("nph")
  if formatter.len == 0:
    stderr.writeLine "onim: nph was not found in PATH"
    return false
  try:
    let formatted = execCmdEx(
      quoteShell(formatter) & " " & quoteShell(filePath),
      options = {poStdErrToStdOut, poUsePath},
      workingDir = splitFile(filePath).dir,
    )
    if formatted.exitCode != 0:
      if formatted.output.len > 0:
        stderr.write formatted.output
      stderr.writeLine "onim: nph failed for " & filePath
      return false
    true
  except CatchableError as error:
    stderr.writeLine "onim: nph failed for " & filePath & ": " & error.msg
    false

when isMainModule:
  if commandLineParams().len > 0 and commandLineParams()[0] == "--semantic-worker":
    runSemanticWorkerProcess()
    quit(0)
  var filePath = ""
  var options = defaultOrganizeOptions()
  var runServer = true
  for argument in commandLineParams():
    if argument == "--help" or argument == "-h":
      usage(stdout)
      quit(0)
    elif argument == "--version" or argument == "-v":
      version(stdout)
      quit(0)
    elif argument == "--stdio" or argument == "--lsp":
      runServer = true
    elif argument.startsWith("--useStdPrefix:"):
      let value = argument["--useStdPrefix:".len .. ^1].toLowerAscii
      options.useStdPrefix =
        value != "off" and value != "false" and value != "0" and value != "no"
    elif argument == "--no-std-prefix":
      options.useStdPrefix = false
    elif argument.startsWith("-"):
      usage(stderr)
      quit 2
    elif filePath.len == 0:
      filePath = argument
      runServer = false
    else:
      usage(stderr)
      quit 2

  if runServer:
    runLsp()
  elif filePath.toLowerAscii.endsWith(".nimble") or
      filePath.toLowerAscii.endsWith(".cfg"):
    quit 0
  elif not fileExists(filePath):
    stderr.writeLine "onim: file not found: " & filePath
    quit 2
  else:
    if organizeFile(filePath, options):
      if filePath.toLowerAscii.endsWith(".nim") and not formatNimFile(filePath):
        quit 1
      echo "organized imports in " & filePath
