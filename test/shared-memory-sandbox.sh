#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-shared-memory-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home-a" "$SANDBOX/home-second"
cat > "$SANDBOX/home-a/config.toml" <<'TOML'
model = "gpt-5.5"
TOML

MOCK_CODEX="$SANDBOX/mock-codex"
cat > "$MOCK_CODEX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'home=%s account=%s active=%s args=%s\n' "${CODEX_HOME:?missing CODEX_HOME}" "${CODEX_ACCOUNT_SLOT:-missing}" "${SECOND_CODEX_ACTIVE_ACCOUNT:-missing}" "$*" > "${SECOND_CODEX_TEST_LOG:?missing SECOND_CODEX_TEST_LOG}"
SH
chmod 700 "$MOCK_CODEX"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
"$REPO_ROOT/second-codex" exec smoke

test -L "$SANDBOX/home-second/memories"
test -L "$SANDBOX/home-second/memories_extensions"
test "$(readlink "$SANDBOX/home-second/memories")" = "$SANDBOX/home-a/memories"
test "$(readlink "$SANDBOX/home-second/memories_extensions")" = "$SANDBOX/home-a/memories_extensions"
grep -Fxq "home=$SANDBOX/home-second account=second active=second args=exec smoke" "$SANDBOX/codex.log"

rm "$SANDBOX/home-second/memories"
mkdir "$SANDBOX/home-second/memories"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$REPO_ROOT/second-codex" exec should-not-run >"$SANDBOX/refuse.out" 2>&1; then
  echo "FAIL non-symlink memory path was not refused"
  exit 1
fi
grep -q "refused to replace existing" "$SANDBOX/refuse.out"

rm -rf "$SANDBOX/home-a/memories" "$SANDBOX/home-second/memories"
echo "not a directory" > "$SANDBOX/home-a/memories"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$REPO_ROOT/second-codex" exec should-not-run >"$SANDBOX/primary-file.out" 2>&1; then
  echo "FAIL primary memory file was not refused"
  exit 1
fi
grep -q "primary .*memories is not a directory" "$SANDBOX/primary-file.out"

echo "PASS shared memory sandbox"
