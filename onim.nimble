# Package

version       = "0.1.0"
author        = "Gabriel Capilla"
description   = "A standalone Nim language server with compiler-backed import organization"
license       = "MIT"
srcDir        = "src"
bin           = @["onim"]
installFiles  = @["stdlib_map.json"]

# Dependencies

requires      "nim >= 2.0.0"

# Tasks

task test, "run the organize-imports regression suite":
  exec "nim c -o:onim --path:src --hints:off --warnings:off src/onim.nim"
  exec "nim c -r --path:src --hints:off --warnings:off tests/torganize.nim"
  exec "nim c -r --path:src --hints:off --warnings:off tests/tlsp.nim"

task generateStdlibMap, "regenerate the compiler-derived stdlib symbol map":
  exec "nim c -r --hints:off --warnings:off gen_stdlib_map.nim"

task bench, "measure warm organize-imports latency":
  exec "nim c --path:src --hints:off --warnings:off bench/bench_organize.nim"
  exec "bench/bench_organize"
