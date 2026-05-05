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
WRAPPER_BASH="${SECOND_CODEX_TEST_BASH:-/bin/bash}"

run_wrapper() {
  SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  SECOND_CODEX_MANIFEST="$REPO_ROOT/ownership-manifest.txt" \
  CODEX_A_HOME="$1" \
  SECOND_CODEX_HOME="$2" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$REPO_ROOT/second-codex" login status
}

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

run_no_errexit_session_id() {
  SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  SECOND_CODEX_MANIFEST="$REPO_ROOT/ownership-manifest.txt" \
  CODEX_A_HOME="$1" \
  SECOND_CODEX_HOME="$2" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$NO_ERREXIT_WRAPPER" session-id --second
}

run_with_manifest() {
  local manifest="$1"
  SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  SECOND_CODEX_MANIFEST="$manifest" \
  CODEX_A_HOME="$SANDBOX/manifest-primary" \
  SECOND_CODEX_HOME="$SANDBOX/manifest-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$WRAPPER_BASH" "$REPO_ROOT/second-codex" login status
}

assert_sparse_manifest_refused() {
  local name="$1"
  local manifest="$2"
  local out="$SANDBOX/$name.out"
  local rc
  set +e
  run_with_manifest "$manifest" >"$out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 66 ]; then
    echo "FAIL sparse manifest $name exited $rc instead of 66" >&2
    cat "$out" >&2
    exit 1
  fi
  grep -q "ownership manifest did not define required pattern groups" "$out"
  if grep -q "unbound variable" "$out"; then
    echo "FAIL sparse manifest $name crashed with bash nounset before validation" >&2
    cat "$out" >&2
    exit 1
  fi
}

mkdir -p "$SANDBOX/manifest-primary" "$SANDBOX/manifest-second"
cat > "$SANDBOX/manifest-missing-environment.txt" <<'MANIFEST'
[account-runtime]
auth.json
MANIFEST
cat > "$SANDBOX/manifest-missing-account.txt" <<'MANIFEST'
[primary-owned-environment]
config.toml
MANIFEST

assert_sparse_manifest_refused missing-environment-manifest "$SANDBOX/manifest-missing-environment.txt"
assert_sparse_manifest_refused missing-account-manifest "$SANDBOX/manifest-missing-account.txt"

mkdir -p "$SANDBOX/empty-primary" "$SANDBOX/home-second"
cat > "$SANDBOX/home-second/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
mkdir -p "$SANDBOX/empty-primary/memories" "$SANDBOX/empty-primary/memories_extensions"
ln -s "$SANDBOX/empty-primary/memories" "$SANDBOX/home-second/memories"
ln -s "$SANDBOX/empty-primary/memories_extensions" "$SANDBOX/home-second/memories_extensions"

if run_wrapper "/" "$SANDBOX/home-second" >"$SANDBOX/root-primary.out" 2>&1; then
  echo "FAIL root primary CODEX_HOME was not refused"
  exit 1
fi
grep -q "refused root primary CODEX_HOME" "$SANDBOX/root-primary.out"

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

if run_wrapper "$SANDBOX/real-primary" "/" >"$SANDBOX/root-second.out" 2>&1; then
  echo "FAIL root second CODEX_HOME was not refused"
  exit 1
fi
grep -q "refused root second CODEX_HOME" "$SANDBOX/root-second.out"

if run_no_errexit_session_id "$SANDBOX/real-primary" "$SANDBOX/real-primary" >"$SANDBOX/no-errexit-same-homes.out" 2>&1; then
  echo "FAIL same CODEX_HOME was not refused with errexit disabled"
  exit 1
fi
grep -q "refused to run because primary and second CODEX_HOME are the same" "$SANDBOX/no-errexit-same-homes.out"
if grep -q "could not find Codex history" "$SANDBOX/no-errexit-same-homes.out"; then
  echo "FAIL session-id body ran after same-home guard failed with errexit disabled" >&2
  cat "$SANDBOX/no-errexit-same-homes.out" >&2
  exit 1
fi

if run_wrapper "$SANDBOX/a-symlink" "$SANDBOX/real-second" >"$SANDBOX/a-symlink.out" 2>&1; then
  echo "FAIL symlinked primary CODEX_HOME was not refused"
  exit 1
fi
grep -q "refused symlinked primary CODEX_HOME" "$SANDBOX/a-symlink.out"

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/real-primary" \
  SECOND_CODEX_HOME="$SANDBOX/real-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  SECOND_CODEX_TEST_DISABLE_RSYNC=1 \
  "$REPO_ROOT/second-codex" login status >"$SANDBOX/no-rsync.out" 2>&1; then
  echo "FAIL missing rsync was not refused"
  exit 1
fi
grep -q "requires rsync" "$SANDBOX/no-rsync.out"

if run_wrapper "$SANDBOX/real-primary" "$SANDBOX/b-symlink" >"$SANDBOX/b-symlink.out" 2>&1; then
  echo "FAIL symlinked second CODEX_HOME was not refused"
  exit 1
fi
grep -q "refused symlinked second CODEX_HOME" "$SANDBOX/b-symlink.out"

mkdir -p "$SANDBOX/ancestor-target/second-home"
cat > "$SANDBOX/ancestor-target/second-home/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
ln -s "$SANDBOX/real-primary/memories" "$SANDBOX/ancestor-target/second-home/memories"
ln -s "$SANDBOX/real-primary/memories_extensions" "$SANDBOX/ancestor-target/second-home/memories_extensions"
ln -s "$SANDBOX/ancestor-target" "$SANDBOX/ancestor-link"
if run_wrapper "$SANDBOX/real-primary" "$SANDBOX/ancestor-link/second-home" >"$SANDBOX/ancestor-symlink.out" 2>&1; then
  echo "FAIL second CODEX_HOME with a symlinked ancestor was not refused"
  exit 1
fi
grep -q "refused symlinked second CODEX_HOME" "$SANDBOX/ancestor-symlink.out"

mkdir -p "$SANDBOX/shim-target"
ln -s "$SANDBOX/shim-target" "$SANDBOX/shim-parent-link"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/real-primary" \
  SECOND_CODEX_HOME="$SANDBOX/real-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim-parent-link/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$REPO_ROOT/second-codex" login status >"$SANDBOX/shim-parent-link.out" 2>&1; then
  echo "FAIL shim directory with a symlinked ancestor was not refused"
  exit 1
fi
grep -q "refused symlinked shim directory" "$SANDBOX/shim-parent-link.out"
test ! -e "$SANDBOX/shim-target/shim/codex"

mkdir -p "$SANDBOX/artifact-primary/generated_images/session-a" "$SANDBOX/artifact-second/generated_images/session-b"
cat > "$SANDBOX/artifact-primary/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
cat > "$SANDBOX/artifact-second/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
printf 'primary image\n' > "$SANDBOX/artifact-primary/generated_images/session-a/primary-only.png"
printf 'second image\n' > "$SANDBOX/artifact-second/generated_images/session-b/second-only.png"
mkdir -p "$SANDBOX/artifact-primary/memories" "$SANDBOX/artifact-primary/memories_extensions"
ln -s "$SANDBOX/artifact-primary/memories" "$SANDBOX/artifact-second/memories"
ln -s "$SANDBOX/artifact-primary/memories_extensions" "$SANDBOX/artifact-second/memories_extensions"
if ! run_wrapper "$SANDBOX/artifact-primary" "$SANDBOX/artifact-second" >"$SANDBOX/artifacts.out" 2>&1; then
  echo "FAIL generated artifact entries blocked sync" >&2
  cat "$SANDBOX/artifacts.out" >&2
  exit 1
fi
if grep -q "generated_images" "$SANDBOX/artifacts.out"; then
  echo "FAIL generated_images was treated as an unknown CODEX_HOME entry" >&2
  cat "$SANDBOX/artifacts.out" >&2
  exit 1
fi
test -f "$SANDBOX/artifact-second/generated_images/session-b/second-only.png"
test ! -e "$SANDBOX/artifact-second/generated_images/session-a/primary-only.png"

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
