#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-doctor-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home-a" "$SANDBOX/home-second"
cat > "$SANDBOX/home-a/config.toml" <<'TOML'
model = "gpt-5.5"
suppress_unstable_features_warning = true

[features]
goals = true
TOML
mkdir -p "$SANDBOX/home-a/memories" "$SANDBOX/home-a/memories_extensions"
ln -s "$SANDBOX/home-a/memories" "$SANDBOX/home-second/memories"
ln -s "$SANDBOX/home-a/memories_extensions" "$SANDBOX/home-second/memories_extensions"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" doctor
