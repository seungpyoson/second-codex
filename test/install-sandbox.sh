#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-install-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/install.out"

test -x "$SANDBOX/install root/second-codex"
test -f "$SANDBOX/install root/ownership-manifest.txt"
test -L "$SANDBOX/home/.codex-second/memories"
test -L "$SANDBOX/home/.codex-second/memories_extensions"
test "$(readlink "$SANDBOX/home/.codex-second/memories")" = "$SANDBOX/home/.codex/memories"
test "$(readlink "$SANDBOX/home/.codex-second/memories_extensions")" = "$SANDBOX/home/.codex/memories_extensions"
grep -Fxq "source \"$SANDBOX/install root/second-codex-shell.zsh\"" "$SANDBOX/home/.zshrc"

echo "PASS install sandbox"
