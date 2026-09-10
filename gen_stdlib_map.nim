import std/os

import onim/stdlib/generator

when isMainModule:
  let config = parseConfig()
  if config.nimExe.len == 0 or config.libPath.len == 0 or config.nimVersion.len == 0:
    stderr.writeLine "gen_stdlib_map: cannot resolve the active Nim toolchain"
    quit 1
  if not generateStdlibMap(config):
    stderr.writeLine "gen_stdlib_map: generation failed"
    quit 1
  echo "generated ", config.outputPath
