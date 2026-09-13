#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
onim_bin=${ONIM_BIN:-"$repo_root/onim"}
require_zed=${ONIM_REQUIRE_ZED:-0}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/onim-accept.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -x "$onim_bin" ]]; then
  printf 'acceptance: executable Onim not found: %s\n' "$onim_bin" >&2
  exit 1
fi

nph_bin=$(command -v nph || true)
if [[ -z "$nph_bin" ]]; then
  printf 'acceptance: nph was not found in PATH\n' >&2
  exit 1
fi

cp "$repo_root/tests/before/walkdir.nim" "$tmp_dir/main.nim"
if ! "$onim_bin" "$tmp_dir/main.nim" >"$tmp_dir/onim.log" 2>&1; then
  cat "$tmp_dir/onim.log" >&2
  exit 1
fi

if ! grep -Fq 'import std/os' "$tmp_dir/main.nim"; then
  printf 'acceptance: CLI did not add import std/os\n' >&2
  exit 1
fi
"$nph_bin" --check "$tmp_dir/main.nim" >/dev/null

sh -c 'case "$1" in *.nimble|*.cfg) cat;; *) exec nph -;; esac' \
  -- "$tmp_dir/main.nim" < "$tmp_dir/main.nim" > "$tmp_dir/main.nim.out"
cmp -s "$tmp_dir/main.nim" "$tmp_dir/main.nim.out"

cp "$tmp_dir/main.nim" "$tmp_dir/main.cfg"
sh -c 'case "$1" in *.nimble|*.cfg) cat;; *) exec nph -;; esac' \
  -- "$tmp_dir/main.cfg" < "$tmp_dir/main.cfg" > "$tmp_dir/main.cfg.out"
cmp -s "$tmp_dir/main.cfg" "$tmp_dir/main.cfg.out"

if pgrep -x onim >/dev/null 2>&1; then
  printf 'acceptance: an Onim process remained after the CLI check\n' >&2
  exit 1
fi

if [[ "$require_zed" == 1 ]]; then
  zeditor_bin=$(command -v zeditor || true)
  if [[ -z "$zeditor_bin" ]]; then
    printf 'acceptance: zeditor was not found in PATH\n' >&2
    exit 1
  fi
  "$zeditor_bin" --version >/dev/null
else
  printf 'acceptance: clean Zed GUI behavior remains a manual gate\n'
fi

printf 'acceptance: Linux CLI, import organization, nph formatting, passthrough, and process cleanup passed\n'
