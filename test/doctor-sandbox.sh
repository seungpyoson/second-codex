#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-doctor-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home-a" "$SANDBOX/home-second"
echo '{bad json' > "$SANDBOX/home-a/auth.json"
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
"$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor-default.out"
grep -q "primary_auth=corrupt auth file" "$SANDBOX/doctor-default.out"

rm "$SANDBOX/home-second/memories" "$SANDBOX/home-second/memories_extensions"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor-missing-links.out" 2>&1; then
  echo "FAIL doctor silently repaired missing shared-memory symlinks"
  exit 1
fi
grep -q "FAIL memories is not a symlink to primary" "$SANDBOX/doctor-missing-links.out"
grep -q "FAIL memories_extensions is not a symlink to primary" "$SANDBOX/doctor-missing-links.out"
test ! -e "$SANDBOX/home-second/memories"
test ! -e "$SANDBOX/home-second/memories_extensions"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor-missing-links-again.out" 2>&1; then
  echo "FAIL doctor repaired missing shared-memory symlinks during diagnostics"
  exit 1
fi
grep -q "FAIL memories is not a symlink to primary" "$SANDBOX/doctor-missing-links-again.out"
grep -q "FAIL memories_extensions is not a symlink to primary" "$SANDBOX/doctor-missing-links-again.out"
test ! -e "$SANDBOX/home-second/memories"
test ! -e "$SANDBOX/home-second/memories_extensions"
ln -s "$SANDBOX/home-a/memories" "$SANDBOX/home-second/memories"
ln -s "$SANDBOX/home-a/memories_extensions" "$SANDBOX/home-second/memories_extensions"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_DOCTOR_SHOW_EMAIL=1 \
"$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor.out"

grep -q "primary_auth=corrupt auth file" "$SANDBOX/doctor.out"
grep -q "PASS no unknown primary CODEX_HOME entries" "$SANDBOX/doctor.out"
grep -q "PASS no unknown second CODEX_HOME entries" "$SANDBOX/doctor.out"
grep -q "PASS memories symlink to primary" "$SANDBOX/doctor.out"
grep -q "PASS memories_extensions symlink to primary" "$SANDBOX/doctor.out"
grep -q "PASS shim exists in owned non-symlink directory" "$SANDBOX/doctor.out"
grep -q "PASS account/auth command blocked" "$SANDBOX/doctor.out"
if grep -q "^FAIL " "$SANDBOX/doctor.out"; then
  cat "$SANDBOX/doctor.out"
  exit 1
fi

cat "$SANDBOX/doctor.out"
