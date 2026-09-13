# Testing Onim

The test suite has two layers:

- Direct feature tests exercise indexed behavior without starting a process.
- `tests/protocol/tlsp_*.nim` exercises stdio framing, lifecycle, cancellation, worker cleanup, and Zed-shaped document changes; `tlsp_feature_session.nim` preserves the cumulative single-session feature sequence.

Tests are grouped by the production boundary they exercise:

- `tests/features/` covers user-facing language features.
- `tests/index/` covers tokens, syntax indexes, scopes, symbols, types, and invariants.
- `tests/workspace/` covers discovery, module catalogs, bootstrap, persistence, and graph state.
- `tests/protocol/` covers the real stdio process and JSON-RPC lifecycle.
- `tests/syntax/` covers lexical and partial-syntax behavior.
- `tests/stdlib/` covers toolchain-derived standard-library metadata.
- `tests/harness/` contains only the shared test harness and its direct tests.
- `tests/before/` and `tests/after/` are organize-import fixtures and remain unchanged.

Suite programs do not import sibling suites. They depend on production modules and, where needed,
the shared harness through the explicit `--path:tests` test command path.

Run the supported checks with:

```sh
nimble test
nimble fuzz
nimble zedCheck
nimble build -d:release
nph --check src tests
git diff --check
```

## Fixture markers

`tests/harness/fixture.nim` keeps positions independent of line-number edits:

- `<|>` marks a cursor.
- `<sel>...</sel>` marks a selection range.
- `//- path.nim` starts another fixture file.

Markers are removed before indexing. Cursor positions retain both the byte offset used by Onim and the UTF-16 position required by LSP. Fixture paths are deterministic and are mapped to a temporary workspace only when a workspace graph is required.

## Invariants

`tests/index/tinvariants.nim` checks that supported same-length edits produce the same token, import, symbol, scope, type, occurrence, and validation data as a fresh index. It also checks malformed and incomplete Nim input for bounded, crash-free indexing.

`tests/harness/tharness.nim` checks fixture parsing, UTF-16 conversion, canonical feature rendering, workspace dependency edges, document versions, shared `didOpen`/`didChange` transitions, cancellation outcomes, response effects, and semantic-generation rejection. `tests/features/tfeature_harness.nim` exercises completion, hover, diagnostics, local definition, references, rename, inlays, and organize-import edits through marker fixtures without starting a process. `tests/harness/source.nim` can open a fixture snapshot through the production workspace for features that require workspace-owned state. `tests/harness/workspace_fs.nim` owns recursive temporary-workspace cleanup for suites that exercise disk-backed state. `tests/harness/render.nim` is intentionally textual and deterministic; it does not rewrite snapshots automatically.

The protocol seam keeps state transitions and deferred response effects testable without a second LSP implementation. `runLsp` remains the only owner of worker, channel, stdio, and JSON-RPC output effects. The real stdio suite remains authoritative for framing, lifecycle, and subprocess behavior.

The stdio suite uses `ONIM_TEST_SEMANTIC_DELAY_MS` and `ONIM_TEST_SEMANTIC_DELAY_GENERATION` only to hold an older worker request during the generation-burst test. It uses `ONIM_TEST_SEMANTIC_EXIT_AFTER_RESPONSE` to verify that a later fallback request starts cleanly after child termination. They are unset in normal sessions.

Keep process tests for transport and lifetime behavior. Add direct feature tests for feature logic, and add a regression only for a public behavior, invariant, malformed input, or reproduced editor failure.

The harness does not claim complete Nim compiler semantics. Macros, generated declarations, unsupported type shapes, and uncertain overloads must remain conservative or use the isolated compiler fallback documented in `docs/capabilities.md`.
