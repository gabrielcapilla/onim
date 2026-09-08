# Capabilities

This matrix describes the current implementation boundary. `native` means the answer comes from Onim's in-memory indexes; `fallback` means an isolated compiler/nimsuggest path may be used; `partial` means only the listed conservative cases are modeled; `unsupported` means Onim returns no result.

| Area                                     | Status                 | Current coverage                                                                                                                                                                                                             |
| ---------------------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Workspace snapshots and dependency graph | native                 | Incremental files, imports/includes, reverse dependents, persisted source indexes, and background bootstrap.                                                                                                                 |
| Project module discovery                 | native / partial       | Project roots, `src`, safe `nim.cfg` paths, root `.nimble` files, local `nimbledeps` package roots or `srcDir` roots, and declared selected user-installed Nimble package roots are indexed; executable `config.nims` remains conservative. |
| Organize imports                         | native / fallback      | `source.organizeImports` adds, removes, sorts, and groups imports for safe indexed cases; uncertain edits are validated through the isolated semantic worker.                                                                |
| Diagnostics                              | native                 | Lexical/syntax issues, missing standard-library imports, and known project-import failures.                                                                                                                                  |
| Definition, implementation, hover, references, rename | native / partial | Local and project symbols, resolved method implementations, aliases, `from` imports, object fields, and shared target identity; generated and ambiguous symbols remain conservative. |
| Completion                               | native / partial       | Locals, unqualified names from unconditional imports, imported module members, `from` aliases, project surfaces, standard-library surfaces, implicit `File` receivers from stdlib metadata, explicit unqualified standard-library nominal annotations, strict direct standard-library nominal-return receivers such as `newHttpClient()`, known object fields, inferred named-tuple sequence elements, explicit generic-object fields, and exact same-file or directly imported-project UFCS procedures, including direct primitive/nominal generic receivers with ordered arguments. General expression-type completion remains unsupported. |
| Type propagation                         | partial                | Primitive literals including width-suffixed `int8`/`uint8`/`float32` forms, canonical primitive annotations, explicit named/primitive `array[...]` and one-level primitive `seq[...]` annotations, homogeneous inferred sequences of named tuple literals, one-level `ref` wrappers, unambiguous direct routine returns including exact primitive `seq[...]` results, and the strict stdlib nominal-return slice used for member completion. |
| LSP assistance                           | native                 | Document symbols/highlights, folding, selection ranges, signature help, semantic tokens, inferred primitive inlay hints, resolved import/include document links, workspace symbols, known type definitions, conservative method implementation navigation, and direct-call hierarchy. |
| LSP transport                            | native                 | Stdio JSON-RPC, full document synchronization, cancellation, stale-result rejection, bounded worker shutdown, and process reaping.                                                                                           |
| CLI                                      | native                 | `onim --stdio`/`--lsp`, `onim file.nim`, `--help`, `--version`, and the internal `--semantic-worker` mode. Changed `.nim` files are formatted with `nph`; `.nimble` and `.cfg` files are ignored.                              |
| Full Nim semantics                       | unsupported / fallback | General overload and generic resolution, macros/templates, generated symbols, complete conditional compilation, effects, and compiler-only type behavior are not yet native; exact UFCS arity selection and direct primitive/nominal generic-object instances are supported only within their bounded native slices. |

## Measured local evidence

These are fixed-workload observations, not guarantees. They were measured on Linux/amd64 with Nim 2.2.10 in the current worktree; rerun `nimble bench` for comparable output.

| Workload                         |         p95 |         p99 |
| -------------------------------- | ----------: | ----------: |
| Incremental source, 100 lines    | 0.030099 ms | 0.032509 ms |
| Incremental source, 1,800 lines  | 0.268482 ms | 0.283761 ms |
| Incremental source, 10,000 lines | 1.397408 ms | 1.501945 ms |
| Workspace rebuild, 256 modules   | 1.148626 ms |           — |
| Workspace symbols, 4,000 symbols | 2.838489 ms |           — |

For a 256-module workspace, the observed cold bootstrap was 54.635785 ms, warm bootstrap 3.525845 ms, cached surface lookup 0.000850 ms, and rebuild 2.461026 ms. The workspace-symbol row is the p95 of 50 no-match LSP queries against 4,000 indexed declarations; it is a direct probe rather than a `nimble bench` workload. Native parent RSS was approximately 24.2 MiB; a fallback request measured approximately 24.8 MiB for the parent and 48.1 MiB for its semantic child, or 72.7 MiB combined RSS. These measurements did not reproduce the reported 2 GiB session.

## Boundary still open

Onim is not yet a complete replacement for `nimsuggest`, `nimlangserver`, or `nimlsp`. The remaining boundary is intentional and isolated: compiler-backed fallback is retained for uncertain organize-import validation and semantic cases that the native index cannot prove. Removing it requires a native acceptance matrix for those cases, not a compatibility shim or a lexical guess.
