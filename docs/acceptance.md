# Acceptance matrix

This is the executable contract for the Linux/Nim 2.2/Zed 0.1 target. The feature tests are the source of truth; this table only indexes them.

Run the reproducible Linux preflight with `nimble zedCheck`. It verifies the built executable, CLI import organization, `nph` formatting, `.cfg` passthrough, and process cleanup. Set `ONIM_REQUIRE_ZED=1` to additionally require the installed `zeditor` binary and verify that it starts far enough to report its version. The preflight does not claim that a GUI session was exercised.

| Capability | Expected contract | Evidence | Boundary |
| --- | --- | --- | --- |
| Initialize and lifecycle | Advertise the supported providers; accept `shutdown`/`exit`; reject invalid lifecycle order. | `tests/protocol/tlsp.nim` lifecycle and envelope tests | stdio process |
| Document sync | Preserve accepted versions and apply full or UTF-16 incremental changes. | `tests/protocol/tlsp.nim` change/version tests; `tests/harness/tharness.nim` position test | native workspace |
| Organize imports | Return validated add/remove/sort/group edits and ignore `.nimble`/`.cfg`. | `tests/features/torganize.nim`; `tests/protocol/tlsp.nim` code-action path | native first, isolated fallback when uncertain |
| Diagnostics | Report local syntax, missing imports, typos, and compiler unused declarations without counting comments or strings. | `tests/features/tdiagnostics.nim`; `tests/protocol/tlsp.nim` diagnostics tests | native plus compiler fallback |
| Completion | Return deterministic, deduplicated labels, details, documentation, origin, and replacement ranges for supported contexts. | `tests/features/tcompletion.nim`; `tests/protocol/tlsp.nim` completion tests | conservative for unknown types/macros |
| Hover | Return signature, module, documentation, declaration range, and inferred local type where indexed. | `tests/features/thover.nim`; marker fixture test | native indexed surface |
| Definition and type definition | Resolve local, project, imported, alias, `from`, field, and supported overload targets; remain conservative when ambiguous. | `tests/features/tdefinition.nim`; `tests/protocol/tlsp.nim` navigation tests | native partial semantics |
| References and rename | Preserve symbol identity across supported local/project graphs and never cross a shadow. | `tests/features/treferences.nim`, `tests/features/trename.nim`, `tests/protocol/tlsp.nim` | native partial semantics |
| Symbols and navigation | Use the workspace index for document symbols, links, highlights, folding, selection ranges, implementation, and call hierarchy. | `tests/protocol/tlsp.nim` navigation coverage | native partial semantics |
| Inlay and signature help | Keep incomplete declarations usable; expose inferred types and indexed call signatures. | `tests/features/tcompletion.nim`, `tests/features/thover.nim`, `tests/protocol/tlsp.nim` | conservative unsupported shapes |
| Semantic tokens | Return valid full-document token streams for indexed syntax. | `tests/protocol/tlsp.nim` semantic-token path | native syntax index |
| Workspace/index/cache | Incremental supported edits match fresh indexes; cache and reverse dependency state remain generation-safe. | `tests/workspace/tworkspace.nim`, `tests/index/tinvariants.nim`, `tests/workspace/tbootstrap.nim` | supported edit proof is intentionally narrow |
| Process lifetime | EOF, launcher death, cancellation, worker completion, and shutdown do not leave workers behind. | `tests/protocol/tlsp.nim` lifetime/cancellation tests | Linux process boundary |
| Zed configuration | The stock Nim adapter launches the configured Onim binary, enables organize-on-save, and passes `.nim` buffers to `nph` while preserving `.nimble`/`.cfg`. | `docs/zed.md`; `nimble zedCheck`; installed configuration and executable checks | reproducible preflight; clean-session behavior remains manual |

The matrix does not claim complete Nim compiler semantics. Macros, templates, generated symbols, complex overloads, and unsupported type shapes must return conservative results or use the isolated fallback boundary documented in `docs/capabilities.md`.

## Manual clean-session gate

The remaining GUI gate cannot be inferred from a binary version check. In a fresh Zed session, open a `.nim` file containing `walkDir` without an import, save it, and verify that Zed applies `import std/os` and formats the file. Then verify completion, hover, diagnostics, shutdown, and that closing the session leaves no `onim` process. Record the observed result and Zed log path before changing the roadmap checkbox.
