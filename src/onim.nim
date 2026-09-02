import std/[os, strutils]

import onim/lsp
import onim/organize

proc usage() =
  stderr.writeLine "usage: onim [--stdio] [--useStdPrefix:on|off] | onim file.nim"

when isMainModule:
  var filePath = ""
  var options = defaultOrganizeOptions()
  var runServer = true
  for argument in commandLineParams():
    if argument == "--stdio" or argument == "--lsp":
      runServer = true
    elif argument.startsWith("--useStdPrefix:"):
      let value = argument["--useStdPrefix:".len .. ^1].toLowerAscii
      options.useStdPrefix =
        value != "off" and value != "false" and value != "0" and value != "no"
    elif argument == "--no-std-prefix":
      options.useStdPrefix = false
    elif argument.startsWith("-"):
      usage()
      quit 2
    elif filePath.len == 0:
      filePath = argument
      runServer = false
    else:
      usage()
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
      echo "organized imports in " & filePath
