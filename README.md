# onim

`onim` is a standalone Nim 2.0+ language server and compiler-backed organize-imports provider. It is an independent implementation; it does not fork `nimlangserver` or `nimsuggest`.

When Zed requests `source.organizeImports`, onim asks the embedded Nim compiler/nimsuggest API for real undeclared-identifier and unused-import diagnostics, resolves missing names against the generated standard-library map, and returns a minimal `WorkspaceEdit`. It removes unused imports and names, then sorts and groups remaining `std/*` imports. The LSP never writes the document. The CLI applies the same edit to a file.

## Build and run

```sh
nimble build
nimble test
./onim path/to/file.nim
```

`onim` without a file argument starts the stdio LSP. `--stdio` and `--lsp` are explicit aliases. `--useStdPrefix:on` is the default; pass `--useStdPrefix:off` or `--no-std-prefix` to emit legacy spellings such as `import os`.

The source adapter uses `nimsuggest/nimsuggest`, which exposes Nim's compiler module graph and semantic passes. Nim 2.0–2.2 installations do not provide a stable `compiler/api.nim` module, so that compiler API boundary is isolated in `src/onim/semantic/compiler_api.nim` rather than depending on a nonexistent module or using a lexical whitelist.

## Source architecture

The implementation is organized by responsibility under `src/onim`:

- `syntax/` owns lexical tokens and structural import/source parsing.
- `index/` owns per-file source indexes, the conservative module-surface symbol
  and numeric occurrence/scope indexes, and their validated disk cache.
- `session/` owns numeric identities, document overlays, snapshots, and the
  workspace dependency graph.
- `features/` owns user-facing language actions such as organize-imports and
  the conservative native definition resolver.
- `semantic/` owns the compiler adapter and its isolated semantic worker.
- `protocol/` owns the LSP transport and request lifecycle.
- `stdlib/` owns generated standard-library symbol data and lookup.

Dependencies flow from protocol and features toward session, index, syntax,
stdlib, and the isolated semantic adapter. The old flat module paths are not
kept as forwarding facades; callers import the domain module they use, which
keeps ownership and compile boundaries explicit.

## Standard-library map

`stdlib_map.json` is generated from the active Nim installation. The generator walks the complete `lib/` tree, records every discovered module, and asks Nim for JSON documentation. It tries the requested `nim doc --json` interface first and falls back to Nim 2.2's `nim jsondoc --stdout:on` spelling. Symbol entries retain kind, arity, and signature data; ambiguous names use arity and a canonical module fallback (`split` → `std/strutils`).

Regenerate after changing Nim versions with:

```sh
nimble generateStdlibMap
```

The generated map is bundled into the executable and may also be overridden with `ONIM_STDLIB_MAP=/path/to/stdlib_map.json`.

## Workspace index

The LSP builds one workspace index when it receives `initialize`. Each Nim file gets a stable numeric `FileId`; its parsed import/include/export references are retained in a compact per-file index, while forward and reverse dependency edges use numeric IDs. A document overlay is authoritative while it is open, so organize-imports reads the same bytes that Zed is editing.

On-disk source indexes are cached under `ONIM_CACHE_DIR` when set, then `XDG_CACHE_HOME/onim`, or `~/.cache/onim`. A project manifest records the canonical module inventory and file stamps; per-module records are keyed by canonical project/module paths and exact source fingerprints. At restart, an unchanged record can be loaded from the manifest without reading or retaining its source text; the exact bytes are hydrated when a feature requests that module. Cache data is acceleration only: an identity, version, checksum, bounds, stamp, or source mismatch falls back to a fresh in-memory index.

Each source index also contains immutable numeric identifier postings, qualified
member pairs, style-aware usage summaries, and explicit uncertainty reasons.
They are reconstructed from the already-cached tokens, imports, and symbols, so
the cache format stays compatible while a warm LSP request can inspect the
preflight data without reparsing. Only a proven comment/string-only no-op skips
the compiler today; uncertain semantic cases remain compiler-authoritative.
The scope index adds one module interval plus conservative routine intervals,
parameter declarations, direct local declarations, and source order without
duplicating identifier strings. Nested blocks, complex headers, and binding
semantics remain explicitly uncertain.

`didOpen` and full-text `didChange` update only the affected file. A changed file invalidates its reverse import/include/export closure, including transitive dependents and cycles exactly once. Filesystem add/delete/recreate transitions reconcile the numeric graph and preserve tombstone IDs without resolving deleted modules. Disk indexes are published only after a stable `stat -> read -> stat` pair. If a non-stdlib dependency cannot be resolved yet, onim conservatively invalidates the whole workspace until the graph becomes complete. Configuration changes invalidate the whole workspace. Code actions are cached by content, dependency, configuration, and stdlib-prefix generations, so repeated requests for an unchanged snapshot do not invoke the compiler again.

The stdio server also keeps semantic organization in a persistent helper process. The helper owns the embedded compiler graph on one thread, while the LSP process remains free to receive edits. `didOpen` and `didChange` prefetch the current snapshot; at most one compiler request is in flight and intermediate edits are coalesced to the newest snapshot for each file. A code action returns from the generation cache when prefetch has completed, without placing compiler work on the LSP request path. The standalone CLI remains synchronous because its process lifetime ends after one file operation.

The index is an orchestration layer, not yet a semantic replacement for Nim. An uncached organize-imports request still asks the embedded compiler/nimsuggest boundary for `undeclared identifier`; the lexical index determines what needs to be refreshed. Field-layout analysis and a future `onim --compact` opt-in remain separate from `source.organizeImports`.

The native symbol index is deliberately narrower than a compiler symbol table:
it stores declaration kinds and exact name-token spans for module-surface
procedures, types, values, and templates. It is persisted as numeric token
references, so cache reloads do not duplicate names or offsets. The first native
definition request resolves one unambiguous same-file module symbol; qualified,
imported, nested, overloaded, and otherwise uncertain references return `null`
until the parser and resolver milestones add scope facts.

Project-module definition lookup uses only published numeric workspace views.
It resolves an unambiguous exported declaration through a direct module
qualifier, import alias, or plain `from` binding without calling the compiler,
loading the target source, or walking the filesystem. Conditional, excluded,
private, overloaded, forward, nested, aliased-symbol, and external-module
cases intentionally return no location.

## Zed

Put `onim` on `PATH`, or expose the executable as an `onim` language-server entry in the Nim language extension. Keep the existing Nim server if desired; onim only contributes the organize-imports action. Add the following to the corresponding parts of `~/.config/zed/settings.json`:

```json
{
  "lsp": {
    "onim": {
      "initialization_options": {
        "useStdPrefix": true
      }
    }
  },
  "languages": {
    "Nim": {
      "language_servers": ["onim", "nimlangserver"],
      "code_actions_on_format": {
        "source.organizeImports": true
      }
    }
  }
}
```

Zed sends the action during save/format. For example, this source:

```nim
for k, v in walkDir("/tmp"):
  echo k
```

receives `import std/os` before the formatter runs. Existing `import`, `from … import …`, aliases, exclusions, conditional blocks, grouped imports, includes, and local definitions are considered; comments and strings are not searched for symbols. `.nimble` and `.cfg` files are ignored. Leave the existing `nph -` formatter configured in Zed so it formats the returned edit afterward.

## Tests and measurement

The fixtures under `tests/before` and `tests/after` cover `walkDir`, `Table`, `parseJson`, ambiguous `split`, adding and removing plain, grouped, and `from` imports, `from`/`except`, aliases, conditionals, includes, ordering, shadowing, comments, strings, BOM, CRLF, and the legacy stdlib spelling.

The warm-path benchmark uses a 1,800-line source:

```sh
nim c --path:src bench/bench_organize.nim
bench/bench_organize
```

It reports median and p95 wall-clock latency after compiler/map warm-up; compiler diagnostics remain the correctness gate for every uncached source.

The workspace benchmark builds a 256-module dependency chain and reports cold
indexing versus a fresh workspace loading the manifest-backed module records:

```sh
nim c -r --path:src --hints:off --warnings:off bench/bench_workspace.nim
```

The warm measurement restores the validated numeric graph rows from the
manifest and reconstructs reverse edges in memory. Any inventory, stamp, cache,
or graph-format mismatch falls back to the normal graph rebuild.

For LSP latency, measure both the first semantic prefetch and a cache-ready request. The first request can include Nim's initial module-graph build; subsequent requests for an unchanged or already-prefetched snapshot are served from the in-memory workspace/action cache.
