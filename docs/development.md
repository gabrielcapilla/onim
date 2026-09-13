# Development

## Requirements

- Nim 2.2.0 or newer within the 2.2.x series;
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

## Project modules

Onim indexes the project root, `src`, safe `nim.cfg` paths, local Nimble dependencies, and only the user-installed packages declared by the project `.nimble` file. It reads literal package metadata without executing `config.nims` or package tasks. Unresolved or dynamic package configuration remains conservative.

## Standard-library data

Onim resolves the active Nim compiler and library directory for the workspace. On
the first use of a toolchain it generates an immutable binary map in the Onim
cache, then reuses that map for later LSP requests and CLI runs. The cache key
includes the compiler path, full Nim version, library path, host OS, and host
CPU, so separate Nim installations do not share an incompatible map.

Prewarm the cache explicitly when desired:

```sh
nimble generateStdlibMap
```

The generator walks the resolved Nim `lib/` tree and uses Nim's JSON
documentation output. The generated files live under the configured Onim cache
root (`$ONIM_CACHE_DIR`, `$XDG_CACHE_HOME/onim`, or `~/.cache/onim`) and are not
part of the repository or package installation. `ONIM_STDLIB_MAP` remains an
explicit JSON or binary override for development and tests; it disables
automatic generation.

## Benchmarks

The project provides bounded benchmark tasks for organization, completion, incremental indexing, workspace hydration, surfaces, and references:

```sh
nimble bench
```

Treat benchmark output as evidence for a fixed workload only. It does not establish a universal latency or memory guarantee. Reproduce memory or process-lifetime reports with a named project, a fixed sequence of LSP messages, and resident-memory/process-tree measurements before changing the architecture.

For protocol evidence, set `ONIM_TRACE_LSP=1`; it emits diagnostic publication events with a hashed URI, versions, numeric snapshot generations, reason, and count, plus code-action request events with a hashed request ID, generations, duration, result state, worker state, and Linux `rssKb`/`peakRssKb` process-memory fields. It never emits source text or paths. Set `ONIM_TRACE_WORKERS=1` to trace semantic/bootstrap worker start, cancellation, interruption, and reap events. Both are disabled by default.

## Capture a Zed diagnostic report

Run the configured client with tracing inherited by the extension process:

```sh
ONIM_TRACE_LSP=1 ONIM_TRACE_WORKERS=1 zeditor --foreground --new /path/to/project 2>zed-onim.log
```

Record `zeditor --version`, `nim --version`, and the Onim commit. Reproduce the smallest edit that produces the phantom diagnostic, then record the file URI, document versions, edit/save order, and the matching `publishDiagnostics` lines from `zed-onim.log`. Do not paste source text into the trace file.

After closing the Zed workspace, verify that no Onim process remains:

```sh
pgrep -af '(^|/)onim( |$)' || true
```

 The report is actionable only when it includes the client sequence and the corresponding trace. Convert that sequence into a focused `tests/protocol/tlsp.nim` replay before changing runtime behavior; an unreproduced report is not evidence for a speculative fix.

## Source layout

The source tree is grouped by responsibility under `src/onim`. Tests are grouped by feature and index boundary under `tests`; fixtures for source transformations are under `tests/before` and `tests/after`. Keep public workflow documentation in `README.md` or `docs/`, and keep implementation contracts close to the owning module.
