# Known limitations

Onim is under active development. The following limitations are intentionally documented instead of hidden behind a “production-ready” claim.

## Semantic coverage

The native analyzer is conservative. It supports exact same-file and directly imported-project UFCS candidates for indexed local and module-level receiver values, with arity selection for complete balanced calls with fixed signatures and contiguous trailing defaults, and direct routine definitions when that arity leaves one candidate. Direct routine returns with exact primitive `seq[...]` types retain their originating snapshot while resolving UFCS members. A narrow standard-library receiver slice recognizes one unconditional ordinary import and either an unqualified explicit nominal annotation or one unambiguous direct nominal return such as `newHttpClient()`; aliases, `from`, excluded, conditional, shadowed, ambiguous, generic, and composite receivers remain unsupported. It supports fields on explicit direct generic-object instances such as `Box[int]` and `Pair[int, string]`, named non-nested tuple aliases, and homogeneous inferred sequences of named tuple literals. Directly resolved macro/template calls are classified as generated uncertainty and intentionally produce no native type. It does not yet model anonymous or positional tuples, nested tuples, varargs overloads, generic procedure inference, constrained generic instantiation, nested containers, macro/template expansion, generated declarations, conditional compilation, or compiler effects. Conditional, aliased, excluded, or uncertain imports may produce no native result or may use the isolated compiler/nimsuggest boundary. A `null` or incomplete result is safer than inventing a definition, completion item, reference, rename, or import edit.

## Editing diagnostics

Phantom diagnostics have been observed while editing Nim files in Zed. The exact reproduction matrix is not yet established. Until this is resolved, treat diagnostics from rapidly changing or incomplete buffers as provisional and report a minimal source plus the LSP message sequence that produced the result.

## Process lifetime and memory

Reports include multiple Onim processes remaining alive and sessions whose total resident memory exceeds 2 GiB. A corrected local Linux probe measured 24.8 MiB parent RSS plus 48.1 MiB semantic-child RSS for a fallback request, 72.7 MiB combined RSS, and no 2 GiB reproduction. The LSP transcript suite also now waits for every process and leaves no Onim child behind. Zed-specific reports remain open until they can be reproduced with the evidence below.

When a client advertises `/` or the user home directory as its workspace root, Onim does not recursively scan that broad root during initialization. The first opened file selects the nearest ancestor containing `nim.cfg`, `config.nims`, or a `.nimble` file; an unmarked file remains locally indexed without workspace discovery. An explicit narrower project root is preserved.

Project and declared-Nimble source discovery share a bounded record budget. The current ceiling
is one million files, directories, and examined entries per discovery pass; exhaustion fails the
pass atomically instead of returning a partial workspace. A warm manifest that exceeds a future
configured ceiling falls back to a bounded cold scan.

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
