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

NO_ERREXIT_WRAPPER="$SANDBOX/second-codex-no-errexit"
awk '
  $0 == "main \"$@\"" {
    print "set +e"
    print
    found += 1
    next
  }
  { print }
  END { if (found != 1) exit 42 }
' "$REPO_ROOT/second-codex" >"$NO_ERREXIT_WRAPPER"
chmod 700 "$NO_ERREXIT_WRAPPER"

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

rm -rf "$SANDBOX/home-second"
mkdir "$SANDBOX/home-second"
echo "not a directory" > "$SANDBOX/home-a-file"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  SECOND_CODEX_MANIFEST="$REPO_ROOT/ownership-manifest.txt" \
  CODEX_A_HOME="$SANDBOX/home-a-file" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$NO_ERREXIT_WRAPPER" exec should-not-run >"$SANDBOX/no-errexit-primary-file.out" 2>&1; then
  echo "FAIL primary file CODEX_HOME was not refused with errexit disabled"
  exit 1
fi
grep -q "Not a directory" "$SANDBOX/no-errexit-primary-file.out"
if [[ -e "$SANDBOX/home-second/memories" || -L "$SANDBOX/home-second/memories" ]]; then
  echo "FAIL shared memories link was created after primary mkdir failed with errexit disabled" >&2
  cat "$SANDBOX/no-errexit-primary-file.out" >&2
  exit 1
fi

echo "PASS shared memory sandbox"
