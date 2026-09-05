# onim

`onim` is a standalone Nim 2.0+ language server and indexed organize-imports provider. It is an independent implementation; it does not fork `nimlangserver` or `nimsuggest`.

When Zed requests `source.organizeImports`, onim first uses the in-memory source index, generated standard-library map, and complete project-module surface to resolve safe cases without starting a compiler process. Ambiguous or unsupported cases use the isolated Nim compiler/nimsuggest boundary for authoritative diagnostics. Onim returns a minimal `WorkspaceEdit`, removes unused imports and names, then sorts and groups remaining `std/*` imports. The LSP never writes the document. The CLI applies the same edit to a file.

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
- `index/` owns per-file source indexes, the conservative module-surface symbol,
  shared module-surface, numeric occurrence/scope indexes, and conservative
  same-file object type shapes, plus their validated disk cache.
- `session/` owns numeric identities, document overlays, snapshots, and the
  workspace dependency graph.
- `features/` owns user-facing language actions such as organize-imports, native
  lexical and field completion, the conservative native definition resolver, and
  indexed document symbols.
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

The generated map is bundled into the executable and may also be overridden with `ONIM_STDLIB_MAP=/path/to/stdlib_map.json`. Onim normalizes valid map entries into the same deterministic module-surface index used by project declarations; malformed or fallback-only data is marked incomplete so native resolution cannot guess.

## Workspace index

The LSP binds the project root and restores manifest metadata during `initialize`; it does not scan the whole workspace on the initialize request path. Each Nim file gets a stable numeric `FileId`; its parsed import/include/export references are retained in a compact per-file index, while forward and reverse dependency edges use numeric IDs. A document overlay is authoritative while it is open, so organize-imports reads the same bytes that Zed is editing. Native local operations are available immediately; an unresolved cross-file definition request performs one conservative workspace bootstrap and retries against the resulting graph.

On-disk source indexes are cached under `ONIM_CACHE_DIR` when set, then `XDG_CACHE_HOME/onim`, or `~/.cache/onim`. A project manifest records the canonical module inventory and file stamps; per-module records are keyed by canonical project/module paths and exact source fingerprints. At restart, an unchanged record can be loaded from the manifest without reading or retaining its source text; the exact bytes are hydrated when a feature requests that module. Cache data is acceleration only: an identity, version, checksum, bounds, stamp, or source mismatch falls back to a fresh in-memory index.

Each source index also contains immutable numeric identifier postings, qualified
member pairs, style-aware usage summaries, and explicit uncertainty reasons.
Its token stream uses a flat immutable base with 64-token copy-on-write blocks,
so a proven same-length identifier edit does not clone the complete token
array. These structures are reconstructed from the already-cached tokens,
imports, and symbols, so the cache format stays compatible while a warm LSP
request can inspect the preflight data without reparsing. Complete conservative
files can organize stdlib and project imports from the native index without
invoking the compiler; uncertain semantic cases remain compiler-authoritative.
Project action keys include a surface generation, so provider-module edits
cannot leave a stale organize result cached for a consumer.
The scope index adds one module interval plus conservative routine intervals,
parameter declarations, direct local declarations, and explicit unnamed
multiline block scopes without duplicating identifier strings. Conditional
control-flow scopes, complex headers, and unsupported binding forms remain
explicitly uncertain.

`didOpen` and full-text `didChange` update only the affected file. A changed file invalidates its reverse import/include/export closure, including transitive dependents and cycles exactly once. Filesystem add/delete/recreate transitions reconcile the numeric graph and preserve tombstone IDs without resolving deleted modules. Disk indexes are published only after a stable `stat -> read -> stat` pair. If a non-stdlib dependency cannot be resolved yet, onim invalidates that unresolved root and its reverse-dependent closure conservatively; unrelated modules remain reusable. Configuration changes invalidate the whole workspace. Code actions are cached by content, dependency, configuration, and stdlib-prefix generations, so repeated requests for an unchanged snapshot do not invoke the compiler again.

The stdio server also keeps semantic organization in a persistent helper process. The helper owns the embedded compiler graph on one thread, while the LSP process remains free to receive edits. `didOpen` and `didChange` prefetch the current snapshot; at most one compiler request is in flight and intermediate edits are coalesced to the newest snapshot for each file. A code action returns from the generation cache when prefetch has completed, without placing compiler work on the LSP request path. The standalone CLI remains synchronous because its process lifetime ends after one file operation.

The index is an orchestration layer, not yet a complete semantic replacement for Nim. The native indexed organizer handles complete, certain stdlib and project-module surfaces; the embedded compiler/nimsuggest boundary remains a fallback for `undeclared identifier`, incomplete project graphs, complex imports, and other unsupported semantic cases. Native syntax and missing-import diagnostics are published independently of that fallback. Field-layout analysis and a future `onim --compact` opt-in remain separate from `source.organizeImports`.

The native symbol and module-surface indexes are deliberately narrower than a
compiler symbol table:
it stores declaration kinds and exact name-token spans for module-surface
procedures, types, values, and templates. It is persisted as numeric token
references, so cache reloads do not duplicate names or offsets. Native definition
lookup resolves one unambiguous same-file module symbol and proven project
exports through direct qualifiers, aliases, and plain `from` bindings. Native
references preserve same-file binding identity and extend those project targets
through the direct reverse dependency graph; unsupported, ambiguous, stale, or
incomplete snapshots return `null` instead of guessing.

Native completion is deliberately conservative: it returns visible parameters
and direct `let`/`var`/`const` declarations from supported routine and
unnamed-block scopes, plus members of one direct imported project or complete
stdlib module. Project completion uses a complete indexed module surface and
graph; canonical `std/...` completion uses the complete bundled surface. Direct
imports, aliases, empty member prefixes, Nim identifier prefixes, and fields of
same-file nominal `object`, `ref object`, and `ptr object` types are supported.
Local fields may come from an explicit annotation or a direct object
constructor. Unsupported contexts return `null` without invoking the compiler
or semantic worker; the response remains marked incomplete while imported type
shapes, UFCS, `from` completion, re-exports, and keyword completion remain
future native milestones.

The shared surface index stores sorted module ranges, normalized identifier keys,
overload records, and deterministic ambiguity results. Project surfaces are
derived from a cached `SourceIndex`; the complete generated stdlib map is
adapted at startup, while incomplete fallback data always returns `unknown`.

Project-module definition lookup uses only published numeric workspace views.
It resolves an unambiguous exported declaration through a direct module
qualifier, import alias, or plain `from` binding without calling the compiler,
loading the target source, or walking the filesystem. Conditional, excluded,
private, overloaded, forward, nested, aliased-symbol, and external-module
cases intentionally return no location. Project references use the persisted
occurrence postings as a prefilter, then hydrate only matching files for exact
UTF-16 locations; conditional, re-exported, generated, or incomplete graphs
return `null` rather than a partial list.

The LSP also publishes document symbols directly from the current source index.
Their names, kinds, and UTF-16 selection ranges are available without invoking
the compiler; declarations outside the conservative native index are omitted
until the parser can represent them safely.

Native hover resolves indexed local definitions, project symbols, and imported
stdlib symbols, including `from` bindings and qualified aliases. Native rename
applies to proven routine locals and exported project symbols across direct
dependents, including qualified aliases, plain `from` bindings, aliased `from`
source names, and unused `from` imports. It returns no edit for ambiguous,
conditional, re-exported, generated, stale, colliding, or otherwise unsupported
bindings instead of guessing.

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

The incremental benchmark compares full indexing with the copy-on-write
identifier path at 100, 1,800, and 10,000 lines:

```sh
nim c -d:release --path:src bench/bench_incremental.nim
bench/bench_incremental
```

It reports median, p95, p99, fallback counts, and edit positions. The fast path
is intentionally conservative; edits that change token boundaries, line
structure, imports, declarations, or uncertain syntax use the complete index
path.

The completion benchmark measures warm local completion, same-file object-field
completion for annotation and constructor receivers with 8, 64, and 512
fields, complete stdlib-module completion, and a 256-member project module with
0, 128, and 512 unrelated modules. It also measures retained memory and stdio
round trips for local and stdlib-member completion:

```sh
nim c -d:release -o:onim-release --path:src --hints:off --warnings:off src/onim.nim
nim c -d:release -o:bench/bench_completion --path:src --hints:off --warnings:off bench/bench_completion.nim
ONIM_BIN="$PWD/onim-release" ./bench/bench_completion
```

The project-member samples verify that unrelated indexed modules do not enter
the request path; the benchmark reports median and p95 latency together with
the returned candidate count.

The workspace benchmark builds a 256-module dependency chain and reports cold
indexing versus a fresh workspace loading the manifest-backed module records:

```sh
nim c -r --path:src --hints:off --warnings:off bench/bench_workspace.nim
```

The warm measurement restores the validated numeric graph rows from the
manifest and reconstructs reverse edges in memory. Any inventory, stamp, cache,
or graph-format mismatch falls back to the normal graph rebuild.

The reference benchmark generates 1,024-module workspaces and reports cold and
warm index time, first-after-restart latency, hot native feature latency, stdio
round-trip latency, overlay invalidation, 16- and 256-dependent fan-out, and
same-spelling local false positives:

```sh
nim c -d:release -o:onim-release --path:src --hints:off --warnings:off src/onim.nim
nim c -d:release -o:bench/bench_references --path:src --hints:off --warnings:off bench/bench_references.nim
ONIM_BIN="$PWD/onim-release" ./bench/bench_references
```

Each result includes median, p95, MAD, result count, candidate count, and
failures. Bootstrap time is reported separately from cache-ready requests.

For LSP latency, measure both the first semantic prefetch and a cache-ready request. The first request can include Nim's initial module-graph build; subsequent requests for an unchanged or already-prefetched snapshot are served from the in-memory workspace/action cache.

The completion benchmark keeps the default run bounded. Set
`ONIM_BENCH_CROSS_FILE=1` to additionally measure qualified and constructor
object-member completion across 8, 64, and 512 fields with 0, 128, and 512
unrelated modules.
