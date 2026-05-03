#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="${TMPDIR:-/tmp}/second-codex-reroute-sandbox-$$"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home-a" "$SANDBOX/home-second"
cat > "$SANDBOX/home-a/config.toml" <<'TOML'
model = "gpt-5.5"
[features]
goals = true
TOML
mkdir -p "$SANDBOX/home-a/memories" "$SANDBOX/home-a/memories_extensions"
ln -s "$SANDBOX/home-a/memories" "$SANDBOX/home-second/memories"
ln -s "$SANDBOX/home-a/memories_extensions" "$SANDBOX/home-second/memories_extensions"

OUT="$SANDBOX/reroute.out"
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" mcp add sandbox-reroute -- /usr/bin/true >"$OUT" 2>&1

grep -q "rerouting environment/config change" "$OUT"
grep -q "sandbox-reroute" "$SANDBOX/home-a/config.toml"
test -f "$SANDBOX/home-second/config.toml"
grep -q "sandbox-reroute" "$SANDBOX/home-second/config.toml"
echo "PASS reroute sandbox"
