# Zed setup

Zed is Onim's first supported editor integration. Install the Nim extension, build Onim, and configure the extension's existing `nim` adapter to launch the local executable.

## Configuration

Add or merge the following settings in `~/.config/zed/settings.json`:

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

Use the absolute path produced by `nimble build`, or use an installed absolute path such as `/home/user/.local/bin/onim`. The `arguments` field is the Zed setting name; `args` is not used by the current extension launcher.

The Nim extension registers the language-server adapter as `nim` and uses `nimlangserver` when no binary override is configured. The `lsp.nim.binary.path` setting replaces that executable with Onim. Therefore, these forms are incorrect for the stock extension:

```json
{
  "languages": {
    "Nim": {
      "language_servers": ["onim", "nimlangserver"]
    }
  }
}
```

```json
{
  "lsp": {
    "onim": {
      "initialization_options": {
        "useStdPrefix": true
      }
    }
  }
}
```

The `language_servers` setting replaces the language's default server list. With the stock Nim extension, keep `"nim"` in that list. Running Onim and `nimlangserver` as two separate Nim servers requires a separate or modified Zed extension that registers another adapter.

## Formatting on save

Keep the existing external formatter if it already invokes `nph`. A formatter that passes `.nim` files to `nph -` and returns `.nimble`/`.cfg` files unchanged is appropriate:

```json
{
  "formatter": {
    "external": {
      "command": "sh",
      "arguments": [
        "-c",
        "case \"$1\" in *.nimble|*.cfg) cat;; *) exec nph -;; esac",
        "--",
        "{buffer_path}"
      ]
    }
  }
}
```

On save, Zed requests `source.organizeImports`, applies the returned edits, and then sends the resulting buffer through the formatter. Onim itself does not write the document during LSP requests.

For example:

```nim
proc main() =
  echo fmt("Hello")
  for k, v in walkDir("/tmp"):
    echo k
```

Onim can return the missing standard-library imports, and `nph` formats the resulting Nim source. `.nimble` and `.cfg` files are ignored by the CLI and should remain passthrough inputs to the formatter.

## Troubleshooting

1. Run `nimble build` and confirm that the configured absolute path exists and is executable.
2. Restart the Nim language server from Zed after changing `settings.json`.
3. Open Zed's log and verify that the Nim adapter launched the configured Onim path.
4. Confirm that `nph` is on the `PATH` visible to Zed.

If several Onim processes remain after closing the relevant Zed sessions, or memory grows beyond expected bounds, record the project, open documents, process tree, and resident memory before restarting Zed. These are active limitations; see [known limitations](known-limitations.md).
