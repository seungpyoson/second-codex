#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-doctor-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home" "$SANDBOX/home-a" "$SANDBOX/home-second"
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

DEFAULT_BLOCK_HOME="$SANDBOX/default-block-home"
DEFAULT_BLOCK_SECOND="$SANDBOX/default-block-second"
mkdir -p "$DEFAULT_BLOCK_HOME" "$DEFAULT_BLOCK_SECOND"
cat > "$DEFAULT_BLOCK_HOME/.zshrc" <<'ZSHRC'
# >>> second-codex shell helper >>>
[[ -r "$HOME/.codex-account-switch/second-codex-shell.zsh" ]] && source "$HOME/.codex-account-switch/second-codex-shell.zsh"
# <<< second-codex shell helper <<<
ZSHRC
HOME="$DEFAULT_BLOCK_HOME" \
SECOND_CODEX_SWITCH_ROOT="$DEFAULT_BLOCK_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$DEFAULT_BLOCK_SECOND" \
ZSHRC="$DEFAULT_BLOCK_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$DEFAULT_BLOCK_HOME/.local/bin" \
"$REPO_ROOT/install.sh" >"$SANDBOX/default-block-install.out"
HOME="$DEFAULT_BLOCK_HOME" \
SECOND_CODEX_SWITCH_ROOT="$DEFAULT_BLOCK_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$DEFAULT_BLOCK_SECOND" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/default-block-shim" \
ZSHRC="$DEFAULT_BLOCK_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$DEFAULT_BLOCK_HOME/.local/bin" \
PATH="$DEFAULT_BLOCK_HOME/.local/bin:$PATH" \
"$DEFAULT_BLOCK_HOME/.local/bin/second-codex" doctor >"$SANDBOX/default-block-doctor.out"
grep -q "PASS shell helper block points to install root" "$SANDBOX/default-block-doctor.out"

LEGACY_HOME="$SANDBOX/doctor-legacy-home"
LEGACY_SECOND="$SANDBOX/doctor-legacy-second"
mkdir -p "$LEGACY_HOME" "$LEGACY_SECOND"
HOME="$LEGACY_HOME" \
SECOND_CODEX_SWITCH_ROOT="$LEGACY_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$LEGACY_SECOND" \
ZSHRC="$LEGACY_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$LEGACY_HOME/.local/bin" \
"$REPO_ROOT/install.sh" >"$SANDBOX/legacy-install.out"
printf "source '%s'\n" "$LEGACY_HOME/.codex-account-switch/second-codex-shell.zsh" > "$LEGACY_HOME/.zshrc"
HOME="$LEGACY_HOME" \
SECOND_CODEX_SWITCH_ROOT="$LEGACY_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$LEGACY_SECOND" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/doctor-legacy-shim" \
ZSHRC="$LEGACY_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$LEGACY_HOME/.local/bin" \
PATH="$LEGACY_HOME/.local/bin:$PATH" \
"$LEGACY_HOME/.local/bin/second-codex" doctor >"$SANDBOX/doctor-legacy.out"
grep -q "PASS shell helper source points to install root" "$SANDBOX/doctor-legacy.out"

COMMENTED_HOME="$SANDBOX/doctor-commented-home"
COMMENTED_SECOND="$SANDBOX/doctor-commented-second"
mkdir -p "$COMMENTED_HOME" "$COMMENTED_SECOND"
HOME="$COMMENTED_HOME" \
SECOND_CODEX_SWITCH_ROOT="$COMMENTED_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$COMMENTED_SECOND" \
ZSHRC="$COMMENTED_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$COMMENTED_HOME/.local/bin" \
"$REPO_ROOT/install.sh" >"$SANDBOX/commented-install.out"
cat > "$COMMENTED_HOME/.zshrc" <<'ZSHRC'
# >>> second-codex shell helper >>>
# [[ -r "$HOME/.codex-account-switch/second-codex-shell.zsh" ]] && source "$HOME/.codex-account-switch/second-codex-shell.zsh"
# <<< second-codex shell helper <<<
ZSHRC
if HOME="$COMMENTED_HOME" \
  SECOND_CODEX_SWITCH_ROOT="$COMMENTED_HOME/.codex-account-switch" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$COMMENTED_SECOND" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/doctor-commented-shim" \
  ZSHRC="$COMMENTED_HOME/.zshrc" \
  SECOND_CODEX_PATH_DIR="$COMMENTED_HOME/.local/bin" \
  PATH="$COMMENTED_HOME/.local/bin:$PATH" \
  "$COMMENTED_HOME/.local/bin/second-codex" doctor >"$SANDBOX/doctor-commented.out" 2>&1; then
  echo "FAIL doctor accepted commented-out shell helper source line"
  cat "$SANDBOX/doctor-commented.out"
  exit 1
fi
grep -q "FAIL shell helper block missing or stale" "$SANDBOX/doctor-commented.out"

MANAGED_HOME="$SANDBOX/doctor-managed-home"
MANAGED_REPO="$SANDBOX/doctor-managed-config"
mkdir -p "$MANAGED_HOME" "$MANAGED_REPO"
printf '# managed config\n' > "$MANAGED_REPO/zshrc"
ln -s "$MANAGED_REPO/zshrc" "$MANAGED_HOME/.zshrc"
HOME="$MANAGED_HOME" \
SECOND_CODEX_SWITCH_ROOT="$MANAGED_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/doctor-managed-second" \
SECOND_CODEX_PATH_DIR="$MANAGED_HOME/.local/bin" \
"$REPO_ROOT/install.sh" >/dev/null 2>&1 || true
HOME="$MANAGED_HOME" \
SECOND_CODEX_SWITCH_ROOT="$MANAGED_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/doctor-managed-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/doctor-managed-shim" \
ZSHRC="$MANAGED_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$MANAGED_HOME/.local/bin" \
"$REPO_ROOT/second-codex" doctor >"$SANDBOX/doctor-managed.out" 2>"$SANDBOX/doctor-managed.err" || true
grep -q "FAIL shell helper block missing or stale in symlink-managed config" "$SANDBOX/doctor-managed.out"
grep -q "Add this block to the real config file yourself" "$SANDBOX/doctor-managed.err"
grep -q "# >>> second-codex shell helper >>>" "$SANDBOX/doctor-managed.err"
grep -q "source '$MANAGED_HOME/.codex-account-switch/second-codex-shell.zsh'" "$SANDBOX/doctor-managed.err"
grep -q "# <<< second-codex shell helper <<<" "$SANDBOX/doctor-managed.err"
if grep -q "Add this block to the real config file yourself" "$SANDBOX/doctor-managed.out"; then
  echo "FAIL doctor wrote symlink-managed shell helper remedy to stdout"
  cat "$SANDBOX/doctor-managed.out"
  exit 1
fi

MALFORMED_HOME="$SANDBOX/doctor-malformed-home"
MALFORMED_SECOND="$SANDBOX/doctor-malformed-second"
mkdir -p "$MALFORMED_HOME" "$MALFORMED_SECOND"
HOME="$MALFORMED_HOME" \
SECOND_CODEX_SWITCH_ROOT="$MALFORMED_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$MALFORMED_SECOND" \
ZSHRC="$MALFORMED_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$MALFORMED_HOME/.local/bin" \
"$REPO_ROOT/install.sh" >"$SANDBOX/malformed-install.out"
cat > "$MALFORMED_HOME/.zshrc" <<'ZSHRC'
# >>> second-codex shell helper >>>
source '$HOME/.codex-account-switch/second-codex-shell.zsh'
ZSHRC
if HOME="$MALFORMED_HOME" \
  SECOND_CODEX_SWITCH_ROOT="$MALFORMED_HOME/.codex-account-switch" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$MALFORMED_SECOND" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/doctor-malformed-shim" \
  ZSHRC="$MALFORMED_HOME/.zshrc" \
  SECOND_CODEX_PATH_DIR="$MALFORMED_HOME/.local/bin" \
  PATH="$MALFORMED_HOME/.local/bin:$PATH" \
  "$MALFORMED_HOME/.local/bin/second-codex" doctor >"$SANDBOX/doctor-malformed.out" 2>&1; then
  echo "FAIL doctor accepted malformed shell helper block"
  cat "$SANDBOX/doctor-malformed.out"
  exit 1
fi
grep -q "FAIL shell helper block missing or stale" "$SANDBOX/doctor-malformed.out"

MISSING_WRAPPER_HOME="$SANDBOX/doctor-missing-wrapper-home"
MISSING_WRAPPER_SECOND="$SANDBOX/doctor-missing-wrapper-second"
mkdir -p "$MISSING_WRAPPER_HOME" "$MISSING_WRAPPER_SECOND"
HOME="$MISSING_WRAPPER_HOME" \
SECOND_CODEX_SWITCH_ROOT="$MISSING_WRAPPER_HOME/.codex-account-switch" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$MISSING_WRAPPER_SECOND" \
ZSHRC="$MISSING_WRAPPER_HOME/.zshrc" \
SECOND_CODEX_PATH_DIR="$MISSING_WRAPPER_HOME/.local/bin" \
"$REPO_ROOT/install.sh" >"$SANDBOX/missing-wrapper-install.out"
rm "$MISSING_WRAPPER_HOME/.codex-account-switch/second-codex"
if SECOND_CODEX_SWITCH_ROOT="$MISSING_WRAPPER_HOME/.codex-account-switch" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$MISSING_WRAPPER_SECOND" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/doctor-missing-wrapper-shim" \
  ZSHRC="$MISSING_WRAPPER_HOME/.zshrc" \
  SECOND_CODEX_PATH_DIR="$MISSING_WRAPPER_HOME/.local/bin" \
  PATH="$MISSING_WRAPPER_HOME/.local/bin:$PATH" \
  "$REPO_ROOT/second-codex" doctor >"$SANDBOX/doctor-missing-wrapper.out" 2>&1; then
  echo "FAIL doctor accepted a missing installed wrapper"
  cat "$SANDBOX/doctor-missing-wrapper.out"
  exit 1
fi
grep -q "FAIL installed wrapper is missing; run second-codex update" "$SANDBOX/doctor-missing-wrapper.out"

HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
SECOND_CODEX_PATH_DIR="$SANDBOX/home/.local/bin" \
"$REPO_ROOT/install.sh" >"$SANDBOX/install.out"

HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
ZSHRC="$SANDBOX/home/.zshrc" \
SECOND_CODEX_PATH_DIR="$SANDBOX/home/.local/bin" \
PATH="$SANDBOX/home/.local/bin:$PATH" \
"$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor-default.out"
grep -q "primary_auth=corrupt auth file" "$SANDBOX/doctor-default.out"

rm "$SANDBOX/home-second/memories" "$SANDBOX/home-second/memories_extensions"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  ZSHRC="$SANDBOX/home/.zshrc" \
  SECOND_CODEX_PATH_DIR="$SANDBOX/home/.local/bin" \
  PATH="$SANDBOX/home/.local/bin:$PATH" \
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
  ZSHRC="$SANDBOX/home/.zshrc" \
  SECOND_CODEX_PATH_DIR="$SANDBOX/home/.local/bin" \
  PATH="$SANDBOX/home/.local/bin:$PATH" \
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
ZSHRC="$SANDBOX/home/.zshrc" \
SECOND_CODEX_PATH_DIR="$SANDBOX/home/.local/bin" \
PATH="$SANDBOX/home/.local/bin:$PATH" \
SECOND_CODEX_DOCTOR_SHOW_EMAIL=1 \
"$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor.out"

grep -q "primary_auth=corrupt auth file" "$SANDBOX/doctor.out"
grep -q "PASS no unknown primary CODEX_HOME entries" "$SANDBOX/doctor.out"
grep -q "PASS no unknown second CODEX_HOME entries" "$SANDBOX/doctor.out"
grep -q "PASS memories symlink to primary" "$SANDBOX/doctor.out"
grep -q "PASS memories_extensions symlink to primary" "$SANDBOX/doctor.out"
grep -q "PASS shim exists in owned non-symlink directory" "$SANDBOX/doctor.out"
grep -q "PASS installed wrapper is current" "$SANDBOX/doctor.out"
grep -q "PASS shell helper block points to install root" "$SANDBOX/doctor.out"
grep -q "PASS PATH entrypoint points to install root" "$SANDBOX/doctor.out"
grep -q "PASS PATH resolves second-codex entrypoint" "$SANDBOX/doctor.out"
grep -q "PASS account/auth command blocked" "$SANDBOX/doctor.out"
if grep -q "^FAIL " "$SANDBOX/doctor.out"; then
  cat "$SANDBOX/doctor.out"
  exit 1
fi

awk '{ if ($0 ~ /^SECOND_CODEX_SWITCH_ROOT=/) { print "  " $0 "  " } else { print } }' \
  "$SANDBOX/home/.local/bin/second-codex" > "$SANDBOX/path-entrypoint-spaced"
mv "$SANDBOX/path-entrypoint-spaced" "$SANDBOX/home/.local/bin/second-codex"
chmod 700 "$SANDBOX/home/.local/bin/second-codex"
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
ZSHRC="$SANDBOX/home/.zshrc" \
SECOND_CODEX_PATH_DIR="$SANDBOX/home/.local/bin" \
PATH="$SANDBOX/home/.local/bin:$PATH" \
"$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor-entrypoint-whitespace.out"
grep -q "PASS PATH entrypoint points to install root" "$SANDBOX/doctor-entrypoint-whitespace.out"

ln -s "$SANDBOX/home/.local/bin" "$SANDBOX/path-link"
HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
ZSHRC="$SANDBOX/home/.zshrc" \
SECOND_CODEX_PATH_DIR="$SANDBOX/home/.local/bin" \
PATH="$SANDBOX/path-link:$PATH" \
SECOND_CODEX_DOCTOR_SHOW_EMAIL=1 \
"$REPO_ROOT/second-codex" doctor > "$SANDBOX/doctor-symlink-path.out"
grep -q "PASS PATH resolves second-codex entrypoint" "$SANDBOX/doctor-symlink-path.out"
if grep -q "FAIL PATH does not resolve second-codex entrypoint" "$SANDBOX/doctor-symlink-path.out"; then
  cat "$SANDBOX/doctor-symlink-path.out"
  exit 1
fi

cat "$SANDBOX/doctor.out"
