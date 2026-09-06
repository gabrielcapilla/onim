# Architecture

Onim is organized around a long-lived workspace snapshot. The current design is an incremental native index with a conservative semantic fallback; it is not yet a complete Nim compiler replacement.

## Boundaries

```text
protocol -> features -> session -> index -> syntax
                         \-> stdlib
                         \-> semantic boundary
```

- `protocol/` owns LSP transport, positions, request dispatch, and response lifecycle.
- `features/` owns user-visible actions such as organize-imports, completion, definitions, references, hover, rename, and document symbols.
- `session/` owns document overlays, snapshots, numeric identities, and the workspace dependency graph.
- `index/` owns per-source indexes, occurrences, scopes, module surfaces, and validated disk persistence.
- `syntax/` owns lexing and conservative structural parsing.
- `stdlib/` owns generated standard-library symbol data and lookup.
- `semantic/` isolates the compiler/nimsuggest boundary and its helper process.

The dependency direction keeps protocol code from owning semantic state and keeps feature code from reparsing or scanning the filesystem when an indexed snapshot is sufficient.

## Workspace lifecycle

The LSP keeps an in-memory document overlay for open files. A full-text change updates the affected source index and invalidates its reverse dependency closure. Numeric file and generation IDs make stale snapshots detectable. Project discovery and module surfaces are retained in the workspace graph; unchanged source records can be restored from the on-disk cache.

The cache is acceleration only. Invalid identities, versions, checksums, bounds, timestamps, or source fingerprints cause a fresh in-memory index to be built. Cache location precedence is:

1. `ONIM_CACHE_DIR`;
2. `XDG_CACHE_HOME/onim`;
3. `~/.cache/onim`.

## Native and semantic paths

The native path uses flat numeric indexes for tokens, declarations, scopes, occurrences, imports, and module surfaces. It answers certain local and direct workspace queries without starting a compiler process. The semantic boundary handles unresolved or unsupported cases conservatively and is isolated from the LSP transport.

Nim macros, templates, overload resolution, generated symbols, complex type inference, and other compiler-dependent constructs are not treated as solved merely because their source text can be lexed. Unknown results are preferable to incorrect edits or navigation.

## Design constraints

The project uses numeric IDs and contiguous records where they simplify ownership, invalidation, cache persistence, or hot-path lookup. Strings and JSON remain at input/output boundaries or in generated data. This is a design constraint, not a guarantee that every current allocation has already been eliminated.

Field-layout analysis is a separate future product. It must not be folded into `source.organizeImports`, because reordering Nim object fields can change ABI, serialization, variant layout, or FFI behavior.
