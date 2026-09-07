# Usage

## Command line

Build the executable first:

```sh
nimble build
```

Apply organize-imports to one Nim source file:

```sh
./onim path/to/file.nim
```

The command adds missing imports, removes unused imports when the source is sufficiently resolved, preserves supported import forms, sorts imports, groups standard-library imports, and writes the file only when an edit is needed. Use `--useStdPrefix:off` or `--no-std-prefix` to emit legacy spellings such as `import os`; the default is `std/` spelling.

These inputs are ignored:

```text
*.nimble
*.cfg
```

The CLI also accepts `--useStdPrefix:on`, `--stdio`, and `--lsp`. Without a file argument, `onim`, `onim --stdio`, and `onim --lsp` start the stdio LSP.

Print the package version with `./onim --version`.

## LSP behavior

The LSP operates over stdio and does not write files itself. Zed applies its returned `WorkspaceEdit` and then runs the configured formatter.

The current native index covers the common local and workspace cases for:

- source organize-imports;
- same-file and direct project-module definitions;
- references and rename for proven bindings;
- local and direct imported-module completion;
- hover and document symbols;
- inferred type inlay hints for resolved literal and direct-call bindings;
- syntax and conservative semantic diagnostics.

Unsupported or uncertain syntax is left unresolved rather than guessed. The current implementation still has a compiler/nimsuggest semantic boundary for cases that cannot be resolved by the native index. This is an implementation detail under active replacement, not a promise that every Nim construct is already supported.

Organize-imports preserves comments and strings, understands `import`, `from`, aliases, exclusions, conditional imports, grouped `std/[...]` imports, includes, exports, and local definitions, and does not duplicate an existing import. It groups remaining standard-library modules alphabetically and leaves non-standard imports as separate lines.
