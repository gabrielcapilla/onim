# Development

## Requirements

- Nim 2.0 or newer;
- Nimble;
- `nph` for Nim formatting;
- a matching Nim installation when regenerating the standard-library map.

## Build and checks

```sh
nimble build
nimble test
nph --check src tests bench gen_stdlib_map.nim
```

`nimble test` builds the executable and runs the organize-imports, LSP, workspace, parser, index, feature, and diagnostic suites defined in `onim.nimble`.

Format changed Nim modules with `nph` before committing. Documentation-only changes do not require a Nim formatter run.

## Standard-library data

Regenerate the compiler-derived map after changing the active Nim installation:

```sh
nimble generateStdlibMap
```

The generator walks the Nim `lib/` tree and uses Nim's JSON documentation output. `stdlib_map.json` is the readable generated source; `stdlib_map.bin` is the bundled binary form used for startup lookup. Review generated changes together and run `nimble test` after regeneration.

## Benchmarks

The project provides bounded benchmark tasks for organization, completion, incremental indexing, workspace hydration, surfaces, and references:

```sh
nimble bench
```

Treat benchmark output as evidence for a fixed workload only. It does not establish a universal latency or memory guarantee. Reproduce memory or process-lifetime reports with a named project, a fixed sequence of LSP messages, and resident-memory/process-tree measurements before changing the architecture.

For protocol evidence, set `ONIM_TRACE_LSP=1`; it emits diagnostic publication events with a hashed URI, versions, numeric snapshot generations, reason, and count, plus code-action request events with a hashed request ID, generations, duration, result state, worker state, and Linux `rssKb`/`peakRssKb` process-memory fields. It never emits source text or paths. Set `ONIM_TRACE_WORKERS=1` to trace semantic/bootstrap worker start, cancellation, interruption, and reap events. Both are disabled by default.

## Source layout

The source tree is grouped by responsibility under `src/onim`. Tests are grouped by feature and index boundary under `tests`; fixtures for source transformations are under `tests/before` and `tests/after`. Keep public workflow documentation in `README.md` or `docs/`, and keep implementation contracts close to the owning module.
