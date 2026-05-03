#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-sync-safety-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

MOCK_CODEX="$SANDBOX/mock-codex"
cat > "$MOCK_CODEX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'home=%s args=%s\n' "${CODEX_HOME:?missing CODEX_HOME}" "$*" >> "${SECOND_CODEX_TEST_LOG:?missing log}"
SH
chmod 700 "$MOCK_CODEX"

run_wrapper() {
  SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$1" \
  SECOND_CODEX_HOME="$2" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$REPO_ROOT/second-codex" login status
}

mkdir -p "$SANDBOX/empty-primary" "$SANDBOX/home-second"
cat > "$SANDBOX/home-second/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
mkdir -p "$SANDBOX/empty-primary/memories" "$SANDBOX/empty-primary/memories_extensions"
ln -s "$SANDBOX/empty-primary/memories" "$SANDBOX/home-second/memories"
ln -s "$SANDBOX/empty-primary/memories_extensions" "$SANDBOX/home-second/memories_extensions"

if run_wrapper "$SANDBOX/empty-primary" "$SANDBOX/home-second" >"$SANDBOX/empty.out" 2>&1; then
  echo "FAIL sparse primary CODEX_HOME was not refused"
  exit 1
fi
grep -q "primary CODEX_HOME has no environment entries" "$SANDBOX/empty.out"
grep -q "model" "$SANDBOX/home-second/config.toml"

mkdir -p "$SANDBOX/real-primary" "$SANDBOX/real-second" "$SANDBOX/linked-second"
cat > "$SANDBOX/real-primary/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
cat > "$SANDBOX/real-second/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
cat > "$SANDBOX/linked-second/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
mkdir -p "$SANDBOX/real-primary/memories" "$SANDBOX/real-primary/memories_extensions"
ln -s "$SANDBOX/real-primary" "$SANDBOX/a-symlink"
ln -s "$SANDBOX/linked-second" "$SANDBOX/b-symlink"
ln -s "$SANDBOX/real-primary/memories" "$SANDBOX/linked-second/memories"
ln -s "$SANDBOX/real-primary/memories_extensions" "$SANDBOX/linked-second/memories_extensions"

if run_wrapper "$SANDBOX/a-symlink" "$SANDBOX/real-second" >"$SANDBOX/a-symlink.out" 2>&1; then
  echo "FAIL symlinked primary CODEX_HOME was not refused"
  exit 1
fi
grep -q "refused symlinked primary CODEX_HOME" "$SANDBOX/a-symlink.out"

if run_wrapper "$SANDBOX/real-primary" "$SANDBOX/b-symlink" >"$SANDBOX/b-symlink.out" 2>&1; then
  echo "FAIL symlinked second CODEX_HOME was not refused"
  exit 1
fi
grep -q "refused symlinked second CODEX_HOME" "$SANDBOX/b-symlink.out"

mkdir -p "$SANDBOX/unknown-primary" "$SANDBOX/unknown-second"
cat > "$SANDBOX/unknown-primary/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
cat > "$SANDBOX/unknown-second/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
touch "$SANDBOX/unknown-primary/unclassified"
mkdir -p "$SANDBOX/unknown-primary/memories" "$SANDBOX/unknown-primary/memories_extensions"
ln -s "$SANDBOX/unknown-primary/memories" "$SANDBOX/unknown-second/memories"
ln -s "$SANDBOX/unknown-primary/memories_extensions" "$SANDBOX/unknown-second/memories_extensions"
if run_wrapper "$SANDBOX/unknown-primary" "$SANDBOX/unknown-second" >"$SANDBOX/unknown.out" 2>&1; then
  echo "FAIL unknown top-level primary entry was not refused"
  exit 1
fi
grep -q "unknown top-level entries" "$SANDBOX/unknown.out"

echo "PASS sync safety sandbox"
