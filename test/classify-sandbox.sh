#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="${TMPDIR:-/tmp}/second-codex-classify-sandbox-$$"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home-a" "$SANDBOX/home-second"
cat > "$SANDBOX/home-a/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
mkdir -p "$SANDBOX/home-a/memories" "$SANDBOX/home-a/memories_extensions"
ln -s "$SANDBOX/home-a/memories" "$SANDBOX/home-second/memories"
ln -s "$SANDBOX/home-a/memories_extensions" "$SANDBOX/home-second/memories_extensions"

MOCK_CODEX="$SANDBOX/mock-codex"
cat > "$MOCK_CODEX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'home=%s args=%s\n' "${CODEX_HOME:?missing CODEX_HOME}" "$*" >> "${SECOND_CODEX_TEST_LOG:?missing SECOND_CODEX_TEST_LOG}"
SH
chmod 700 "$MOCK_CODEX"

run_wrapper() {
  SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$REPO_ROOT/second-codex" "$@"
}

if run_wrapper login >"$SANDBOX/login.out" 2>&1; then
  echo "FAIL login was not blocked"
  exit 1
fi
grep -q "refused this account/auth command" "$SANDBOX/login.out"
test ! -f "$SANDBOX/codex.log"

run_wrapper login status
grep -q "home=$SANDBOX/home-second args=login status" "$SANDBOX/codex.log"

run_wrapper --config=model=gpt-5.5 mcp add parser-test -- /usr/bin/true >"$SANDBOX/reroute.out" 2>&1
grep -q "rerouting environment/config change" "$SANDBOX/reroute.out"
grep -q "home=$SANDBOX/home-a args=--config=model=gpt-5.5 mcp add parser-test -- /usr/bin/true" "$SANDBOX/codex.log"

run_wrapper --enable goals features enable another-feature >"$SANDBOX/features.out" 2>&1
grep -q "rerouting environment/config change" "$SANDBOX/features.out"
grep -q "home=$SANDBOX/home-a args=--enable goals features enable another-feature" "$SANDBOX/codex.log"

echo "PASS classify sandbox"
