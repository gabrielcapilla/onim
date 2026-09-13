# onim

`onim` is an independent Nim language server focused initially on Zed. It provides indexed source organization, navigation, completion, hover, references, rename, and diagnostics while the project is being developed toward a complete native Nim language tool.

Onim is active development software. It is not yet a complete replacement for every semantic capability of `nimsuggest`, `nimlangserver`, or `nimlsp`. Version 0.1.0 is verified on Linux with Nim 2.2.x; other platforms are not release claims yet. The current supported integration target is Zed; known limitations are recorded in [docs/known-limitations.md](docs/known-limitations.md).

## Build

Requirements: Nim 2.2 or newer, Nimble, and `nph` for formatting Nim files.

```sh
nimble build
nimble test
nimble zedCheck
```

`nimble zedCheck` verifies the reproducible Linux organizer/formatter preflight; a clean Zed GUI session remains a manual acceptance step.

The executable is `onim`. Running it with a file applies organize-imports edits:

```sh
./onim path/to/file.nim
```

Running `onim` without a file starts its stdio LSP. See [Usage](docs/usage.md) for options and behavior.

## Zed

The stock Nim extension registers its adapter as `nim`. Configure that adapter to launch the Onim executable; do not add `onim` as a language-server ID:

```json
{
  "lsp": {
    "nim": {
      "binary": {
        "path": "/absolute/path/to/onim",
        "arguments": []
      },
      "initialization_options": {
        "useStdPrefix": true
      }
    }
  },
  "languages": {
    "Nim": {
      "language_servers": ["nim"],
      "format_on_save": "on",
      "code_actions_on_format": {
        "source.organizeImports": true
      }
    }
  }
}
```

Merge these keys into `~/.config/zed/settings.json` and keep the existing `nph` formatter configuration. Zed applies Onim's organize-imports edit before running the formatter. The complete setup and troubleshooting notes are in [docs/zed.md](docs/zed.md).

## Documentation

- [Zed setup](docs/zed.md)
- [Usage and supported behavior](docs/usage.md)
- [Architecture](docs/architecture.md)
- [Capabilities and measurements](docs/capabilities.md)
- [Acceptance matrix](docs/acceptance.md)
- [Testing](docs/testing.md)
- [Development](docs/development.md)
- [Known limitations](docs/known-limitations.md)

## License

MIT.
