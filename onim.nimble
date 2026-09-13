# Package

version = "0.1.0"
author = "Gabriel Capilla"
description = "A standalone Nim language server"
license = "MIT"
srcDir = "src"
bin = @["onim"]

# Dependencies

requires "nim >= 2.2.0"

# Tasks

task test, "run the organize-imports regression suite":
  exec "nim c -o:onim --path:src --hints:off --warnings:off src/onim.nim"
  exec "./onim --generate-stdlib-map"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/harness/tharness.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tfeature_harness.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/torganize_edits.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/torganize_native.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/torganize_project.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_lifecycle.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_semantic_workers.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_feature_session.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_project_navigation.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_document_links.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_diagnostics.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_completion.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_protocol_validation.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_document_state.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/protocol/tlsp_semantic_diagnostics.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/workspace/tworkspace_startup.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/workspace/tworkspace_graph.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/workspace/tworkspace_projects.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/workspace/tworkspace_incremental.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/index/tinvariants.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/index/tsymbols.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/index/toccurrences.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/index/tscopes.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/syntax/tparser.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/thover.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/trename.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tdefinition_local.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tdefinition_members.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tdefinition_states.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/treferences.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/index/tbindings.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tcompletion_locals.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tcompletion_members.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tcompletion_project.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tcompletion_typed_members.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/index/tsurfaces.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/features/tdiagnostics.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/workspace/tmodules.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/workspace/tbootstrap.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/stdlib/tstdlibmap.nim"
  exec "nim c -r -d:onimTest --path:src --path:tests --hints:off --warnings:off tests/workspace/tdiscovery.nim"
  exec "nim c -r --path:src --path:tests --hints:off --warnings:off tests/syntax/tsyntax.nim"

task generateStdlibMap, "regenerate the compiler-derived stdlib symbol map":
  exec "nim c -o:onim --path:src --hints:off --warnings:off src/onim.nim"
  exec "./onim --generate-stdlib-map"

task fuzz, "run the extended deterministic index mutation suite":
  exec "ONIM_INVARIANT_TRIALS=4096 nim c -r --path:src --path:tests --hints:off --warnings:off tests/index/tinvariants.nim"

task zedCheck, "verify the reproducible Linux/Zed acceptance preflight":
  exec "sh scripts/accept-linux-zed.sh"

task bench, "measure organize-imports and workspace-index latency":
  exec "nim c --path:src --hints:off --warnings:off bench/bench_organize.nim"
  exec "bench/bench_organize"
  exec "nim c --path:src --hints:off --warnings:off bench/bench_completion.nim"
  exec "bench/bench_completion"
  exec "nim c --path:src --hints:off --warnings:off bench/bench_incremental.nim"
  exec "bench/bench_incremental"
  exec "nim c --path:src --hints:off --warnings:off bench/bench_workspace.nim"
  exec "bench/bench_workspace"
  exec "nim c --path:src --hints:off --warnings:off bench/bench_surface.nim"
  exec "bench/bench_surface"
  exec "nim c --path:src --hints:off --warnings:off bench/bench_references.nim"
  exec "bench/bench_references"
