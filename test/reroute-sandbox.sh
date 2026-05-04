#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-reroute-sandbox.XXXXXX")"
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

MOCK_CODEX="$SANDBOX/mock-codex"
cat > "$MOCK_CODEX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "mcp" && "${2:-}" == "add" ]]; then
  if [[ "${CODEX_HOME:?missing CODEX_HOME}" != "${SECOND_CODEX_EXPECT_PRIMARY:?missing SECOND_CODEX_EXPECT_PRIMARY}" ]]; then
    echo "mock codex expected primary CODEX_HOME, got $CODEX_HOME" >&2
    exit 65
  fi
  if [[ "${CODEX_ACCOUNT_SLOT:-missing}" != "primary" || "${SECOND_CODEX_ACTIVE_ACCOUNT:-missing}" != "primary" ]]; then
    echo "mock codex expected primary account marker, got CODEX_ACCOUNT_SLOT=${CODEX_ACCOUNT_SLOT:-missing} SECOND_CODEX_ACTIVE_ACCOUNT=${SECOND_CODEX_ACTIVE_ACCOUNT:-missing}" >&2
    exit 65
  fi
  printf '\n[mcp_servers.%s]\ncommand = "%s"\n' "$3" "$5" >> "${CODEX_HOME:?missing CODEX_HOME}/config.toml"
  if [[ "$3" == "sandbox-reroute-fail" ]]; then
    exit 42
  fi
  exit 0
fi
echo "unexpected mock codex invocation: $*" >&2
exit 64
SH
chmod 700 "$MOCK_CODEX"

OUT="$SANDBOX/reroute.out"
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
SECOND_CODEX_EXPECT_PRIMARY="$SANDBOX/home-a" \
"$REPO_ROOT/second-codex" mcp add sandbox-reroute -- /usr/bin/true >"$OUT" 2>&1

grep -q "rerouting environment/config change" "$OUT"
grep -q "sandbox-reroute" "$SANDBOX/home-a/config.toml"
test -f "$SANDBOX/home-second/config.toml"
# The second home is updated by sync_projection after the primary-home reroute finishes.
grep -q "sandbox-reroute" "$SANDBOX/home-second/config.toml"

FAIL_OUT="$SANDBOX/reroute-fail.out"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_EXPECT_PRIMARY="$SANDBOX/home-a" \
  "$REPO_ROOT/second-codex" mcp add sandbox-reroute-fail -- /usr/bin/false >"$FAIL_OUT" 2>&1; then
  echo "FAIL failing reroute unexpectedly succeeded"
  exit 1
fi
grep -q "sandbox-reroute-fail" "$SANDBOX/home-a/config.toml"
grep -q "sandbox-reroute-fail" "$SANDBOX/home-second/config.toml"
echo "PASS reroute sandbox"
