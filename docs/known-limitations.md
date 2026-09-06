# Known limitations

Onim is under active development. The following limitations are intentionally documented instead of hidden behind a “production-ready” claim.

## Semantic coverage

The native analyzer is conservative. It does not yet model all Nim overload resolution, generic instantiation, UFCS, macro/template expansion, generated declarations, conditional compilation, or compiler effects. Those cases may produce no native result or may use the isolated compiler/nimsuggest boundary. A `null` or incomplete result is safer than inventing a definition, completion item, reference, rename, or import edit.

## Editing diagnostics

Phantom diagnostics have been observed while editing Nim files in Zed. The exact reproduction matrix is not yet established. Until this is resolved, treat diagnostics from rapidly changing or incomplete buffers as provisional and report a minimal source plus the LSP message sequence that produced the result.

## Process lifetime and memory

Reports include multiple Onim processes remaining alive and sessions whose total resident memory exceeds 2 GiB. This is not an intended memory budget or a validated normal operating profile. The process model and retained workspace/compiler state require measurement on a reproducible project before optimization claims can be made.

When investigating, capture:

- Onim command lines and parent process IDs;
- the number of open Zed worktrees and Nim documents;
- resident memory for each process and the total;
- whether each process has a semantic worker child;
- the LSP initialize, open, change, save, shutdown, and exit sequence.

Do not delete cache data as a first diagnostic step. Cache files are acceleration data and can be inspected or moved aside after the process and workspace evidence has been recorded.

## Editor scope

Zed is the first supported client. Other editors and extension-specific launchers are not part of the current integration contract.

## Future work

The project is intended to move toward a native, incremental Nim analysis engine inspired by `gopls`, `ols`, and `rust-analyzer`. Type propagation, compiler-independent semantic resolution, robust lifecycle cancellation, and memory ownership are development work, not completed features. Field-layout suggestions remain separate from organize-imports.
