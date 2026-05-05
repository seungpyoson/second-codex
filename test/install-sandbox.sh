#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-install-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install \"root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
ZSHENV="$SANDBOX/home/.zshenv" \
"$REPO_ROOT/install.sh" >"$SANDBOX/install.out"

test -x "$SANDBOX/install \"root/second-codex"
test -f "$SANDBOX/install \"root/ownership-manifest.txt"
test "$(cat "$SANDBOX/install \"root/source-root")" = "$REPO_ROOT"
test -x "$SANDBOX/home/.local/bin/second-codex"
grep -Fxq "SECOND_CODEX_SWITCH_ROOT='$SANDBOX/install \"root' exec '$SANDBOX/install \"root/second-codex' \"\$@\"" "$SANDBOX/home/.local/bin/second-codex"
test -L "$SANDBOX/home/.codex-second/memories"
test -L "$SANDBOX/home/.codex-second/memories_extensions"
test "$(readlink "$SANDBOX/home/.codex-second/memories")" = "$SANDBOX/home/.codex/memories"
test "$(readlink "$SANDBOX/home/.codex-second/memories_extensions")" = "$SANDBOX/home/.codex/memories_extensions"
grep -Fxq "# >>> second-codex shell helper >>>" "$SANDBOX/home/.zshrc"
grep -Fxq "# <<< second-codex shell helper <<<" "$SANDBOX/home/.zshrc"
if [ "$(grep -c "second-codex-shell.zsh" "$SANDBOX/home/.zshrc")" -ne 1 ]; then
  echo "FAIL installer wrote duplicate helper source lines on fresh install"
  cat "$SANDBOX/home/.zshrc"
  exit 1
fi
HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install \"root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
ZSHENV="$SANDBOX/home/.zshenv" \
"$REPO_ROOT/install.sh" >"$SANDBOX/install-rerun.out"
if [ "$(grep -c "second-codex-shell.zsh" "$SANDBOX/home/.zshrc")" -ne 1 ]; then
  echo "FAIL installer appended duplicate helper source line on rerun"
  cat "$SANDBOX/home/.zshrc"
  exit 1
fi
if [[ -e "$SANDBOX/home/.zshenv" ]] && grep -Fq "second-codex-shell.zsh" "$SANDBOX/home/.zshenv"; then
  echo "FAIL installer sourced helper from .zshenv"
  exit 1
fi

HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_REAL_CODEX="$SANDBOX/mock-unused-codex" \
  "$SANDBOX/home/.local/bin/second-codex" account >"$SANDBOX/path-entrypoint.out"
grep -Fq "account_slot=second" "$SANDBOX/path-entrypoint.out"

printf '\n# stale-installed-copy\n' >> "$SANDBOX/install \"root/second-codex"
HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install \"root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
"$SANDBOX/home/.local/bin/second-codex" update >"$SANDBOX/update.out"
grep -Fq "Updated second-codex install from $REPO_ROOT" "$SANDBOX/update.out"
if grep -Fq "# stale-installed-copy" "$SANDBOX/install \"root/second-codex"; then
  echo "FAIL second-codex update did not refresh installed wrapper from recorded source"
  exit 1
fi
if [ "$(grep -c "second-codex-shell.zsh" "$SANDBOX/home/.zshrc")" -ne 1 ]; then
  echo "FAIL second-codex update duplicated helper source line"
  cat "$SANDBOX/home/.zshrc"
  exit 1
fi

printf '\n# stale-installed-copy\n' >> "$SANDBOX/install \"root/second-codex"
HOME="$SANDBOX/home" \
SECOND_CODEX_TEST_FORCE_STALE_WARNING=1 \
  "$SANDBOX/home/.local/bin/second-codex" account >"$SANDBOX/stale-first.out" 2>"$SANDBOX/stale-first.err"
grep -Fq "second-codex: installed wrapper is stale. Run \`second-codex update\`." "$SANDBOX/stale-first.err"
HOME="$SANDBOX/home" \
SECOND_CODEX_TEST_FORCE_STALE_WARNING=1 \
  "$SANDBOX/home/.local/bin/second-codex" account >"$SANDBOX/stale-second.out" 2>"$SANDBOX/stale-second.err"
if grep -Fq "installed wrapper is stale" "$SANDBOX/stale-second.err"; then
  echo "FAIL stale install warning repeated after version was acknowledged"
  cat "$SANDBOX/stale-second.err"
  exit 1
fi
HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install \"root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
"$SANDBOX/home/.local/bin/second-codex" update >"$SANDBOX/update-after-stale.out"

printf '\n# local manifest customization\ncustom-local-entry\n' >> "$SANDBOX/install \"root/ownership-manifest.txt"
HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install \"root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
"$SANDBOX/home/.local/bin/second-codex" update >"$SANDBOX/update-after-manifest-custom.out"
if grep -Fq "custom-local-entry" "$SANDBOX/install \"root/ownership-manifest.txt"; then
  echo "FAIL update left local manifest customization in bundled manifest"
  exit 1
fi
manifest_backup="$(find "$SANDBOX/install \"root" -name 'ownership-manifest.txt.local-backup-*' -print -quit)"
if [[ -z "$manifest_backup" ]]; then
  echo "FAIL update did not preserve customized installed ownership manifest"
  exit 1
fi
grep -Fq "custom-local-entry" "$manifest_backup"

SHRINK_SOURCE="$SANDBOX/shrink-source"
mkdir -p "$SHRINK_SOURCE/lib"
cp "$REPO_ROOT/install.sh" "$SHRINK_SOURCE/install.sh"
cp "$REPO_ROOT/second-codex-shell.zsh" "$SHRINK_SOURCE/second-codex-shell.zsh"
cp "$REPO_ROOT/ownership-manifest.txt" "$SHRINK_SOURCE/ownership-manifest.txt"
cp "$REPO_ROOT/README.md" "$SHRINK_SOURCE/README.md"
cp "$REPO_ROOT/lib/session_convert.py" "$SHRINK_SOURCE/lib/session_convert.py"
cat > "$SHRINK_SOURCE/second-codex" <<'WRAPPER'
#!/usr/bin/env bash
echo shrink-wrapper "$@"
WRAPPER
chmod +x "$SHRINK_SOURCE/install.sh" "$SHRINK_SOURCE/second-codex"
printf '%s\n' "$SHRINK_SOURCE" > "$SANDBOX/install \"root/source-root"
HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install \"root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
"$SANDBOX/home/.local/bin/second-codex" update >"$SANDBOX/update-shrink.out"
grep -Fq "Updated second-codex install from $SHRINK_SOURCE" "$SANDBOX/update-shrink.out"
grep -Fq 'echo shrink-wrapper "$@"' "$SANDBOX/install \"root/second-codex"

PRESEEDED_HOME="$SANDBOX/preseed-home"
mkdir -p "$PRESEEDED_HOME"
cat > "$PRESEEDED_HOME/.zshrc" <<'ZSHRC'
# >>> second-codex shell helper >>>
[[ -r "$HOME/.codex-account-switch/second-codex-shell.zsh" ]] && source "$HOME/.codex-account-switch/second-codex-shell.zsh"
# <<< second-codex shell helper <<<
ZSHRC
HOME="$PRESEEDED_HOME" \
CODEX_A_HOME="$PRESEEDED_HOME/.codex" \
SECOND_CODEX_HOME="$PRESEEDED_HOME/.codex-second" \
ZSHRC="$PRESEEDED_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/preseed-install.out"
if [ "$(grep -c "second-codex-shell.zsh" "$PRESEEDED_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer appended duplicate helper source line to existing marker block"
  cat "$PRESEEDED_HOME/.zshrc"
  exit 1
fi
if grep -Fq "source '$PRESEEDED_HOME/.codex-account-switch/second-codex-shell.zsh'" "$PRESEEDED_HOME/.zshrc"; then
  echo "FAIL installer appended unmarked absolute helper source line to existing marker block"
  cat "$PRESEEDED_HOME/.zshrc"
  exit 1
fi

LEGACY_HOME="$SANDBOX/legacy-home"
mkdir -p "$LEGACY_HOME"
printf "source '%s'\n" "$LEGACY_HOME/.codex-account-switch/second-codex-shell.zsh" > "$LEGACY_HOME/.zshrc"
HOME="$LEGACY_HOME" \
CODEX_A_HOME="$LEGACY_HOME/.codex" \
SECOND_CODEX_HOME="$LEGACY_HOME/.codex-second" \
ZSHRC="$LEGACY_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/legacy-install.out"
if [ "$(grep -c "second-codex-shell.zsh" "$LEGACY_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer appended duplicate helper source line to exact legacy source line"
  cat "$LEGACY_HOME/.zshrc"
  exit 1
fi
if grep -Fxq "# >>> second-codex shell helper >>>" "$LEGACY_HOME/.zshrc"; then
  echo "FAIL installer rewrote exact legacy source line instead of preserving it"
  cat "$LEGACY_HOME/.zshrc"
  exit 1
fi

MOVED_HOME="$SANDBOX/moved-home"
mkdir -p "$MOVED_HOME"
cat > "$MOVED_HOME/.zshrc" <<ZSHRC
# >>> second-codex shell helper >>>
source '$MOVED_HOME/old-root/second-codex-shell.zsh'
# <<< second-codex shell helper <<<
ZSHRC
HOME="$MOVED_HOME" \
SECOND_CODEX_SWITCH_ROOT="$MOVED_HOME/new-root" \
CODEX_A_HOME="$MOVED_HOME/.codex" \
SECOND_CODEX_HOME="$MOVED_HOME/.codex-second" \
ZSHRC="$MOVED_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/moved-install.out"
grep -Fxq "source '$MOVED_HOME/new-root/second-codex-shell.zsh'" "$MOVED_HOME/.zshrc"
if grep -Fq "$MOVED_HOME/old-root/second-codex-shell.zsh" "$MOVED_HOME/.zshrc"; then
  echo "FAIL installer left stale helper source path in marked block"
  cat "$MOVED_HOME/.zshrc"
  exit 1
fi
if [ "$(grep -c "second-codex-shell.zsh" "$MOVED_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer duplicated helper source line while updating marked block"
  cat "$MOVED_HOME/.zshrc"
  exit 1
fi

MANAGED_HOME="$SANDBOX/managed-home"
MANAGED_REPO="$SANDBOX/managed-config"
mkdir -p "$MANAGED_HOME" "$MANAGED_REPO"
printf '# managed shell config\n' > "$MANAGED_REPO/zshrc"
ln -s "$MANAGED_REPO/zshrc" "$MANAGED_HOME/.zshrc"
if HOME="$MANAGED_HOME" \
  CODEX_A_HOME="$MANAGED_HOME/.codex" \
  SECOND_CODEX_HOME="$MANAGED_HOME/.codex-second" \
  ZSHRC="$MANAGED_HOME/.zshrc" \
  "$REPO_ROOT/install.sh" >"$SANDBOX/managed-install.out" 2>&1; then
  echo "FAIL installer mutated symlink-managed .zshrc instead of failing loud"
  cat "$SANDBOX/managed-install.out"
  exit 1
fi
if grep -Fq "second-codex-shell.zsh" "$MANAGED_REPO/zshrc"; then
  echo "FAIL installer appended helper source line through symlink-managed .zshrc"
  cat "$MANAGED_REPO/zshrc"
  exit 1
fi
grep -Fq "Refusing to edit symlink-managed shell config" "$SANDBOX/managed-install.out"
grep -Fq "Add this block to the real config file yourself" "$SANDBOX/managed-install.out"

MANAGED_STALE_HOME="$SANDBOX/managed-stale-home"
MANAGED_STALE_REPO="$SANDBOX/managed-stale-config"
mkdir -p "$MANAGED_STALE_HOME" "$MANAGED_STALE_REPO"
cat > "$MANAGED_STALE_REPO/zshrc" <<'ZSHRC'
# >>> second-codex shell helper >>>
source '/old/root/second-codex-shell.zsh'
# <<< second-codex shell helper <<<
ZSHRC
ln -s "$MANAGED_STALE_REPO/zshrc" "$MANAGED_STALE_HOME/.zshrc"
if HOME="$MANAGED_STALE_HOME" \
  SECOND_CODEX_SWITCH_ROOT="$MANAGED_STALE_HOME/new-root" \
  CODEX_A_HOME="$MANAGED_STALE_HOME/.codex" \
  SECOND_CODEX_HOME="$MANAGED_STALE_HOME/.codex-second" \
  ZSHRC="$MANAGED_STALE_HOME/.zshrc" \
  "$REPO_ROOT/install.sh" >"$SANDBOX/managed-stale-install.out" 2>&1; then
  echo "FAIL installer updated stale marked block through symlink-managed .zshrc"
  cat "$SANDBOX/managed-stale-install.out"
  exit 1
fi
grep -Fq "source '/old/root/second-codex-shell.zsh'" "$MANAGED_STALE_REPO/zshrc"
grep -Fq "Refusing to edit symlink-managed shell config" "$SANDBOX/managed-stale-install.out"

MISSING_PARENT_HOME="$SANDBOX/missing-parent-home"
mkdir -p "$MISSING_PARENT_HOME"
if HOME="$MISSING_PARENT_HOME" \
  CODEX_A_HOME="$MISSING_PARENT_HOME/.codex" \
  SECOND_CODEX_HOME="$MISSING_PARENT_HOME/.codex-second" \
  ZSHRC="$MISSING_PARENT_HOME/.config/zsh/.zshrc" \
  "$REPO_ROOT/install.sh" >"$SANDBOX/missing-parent-install.out" 2>&1; then
  echo "FAIL installer created or wrote to a shell config with missing parent directory"
  cat "$SANDBOX/missing-parent-install.out"
  exit 1
fi
grep -Fq "Refusing to edit shell config because its parent directory does not exist" "$SANDBOX/missing-parent-install.out"

cat > "$SANDBOX/install \"root/second-codex" <<'SH'
#!/usr/bin/env bash
printf 'installed-helper:%s\n' "$*" >> "${SECOND_CODEX_INSTALL_HELPER_LOG:?missing log}"
SH
chmod 700 "$SANDBOX/install \"root/second-codex"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -c 'source "$1"; second-codex login status' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:login status" "$SANDBOX/helper.log"
env -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'source "$1"; [[ -z ${SECOND_CODEX_SHELL_HELPER_DIR+x} ]]' \
  _ "$SANDBOX/install \"root/second-codex-shell.zsh"

: > "$SANDBOX/helper.log"
mkdir -p "$SANDBOX/shell-snapshots"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -c 'source "$1"; typeset -f -m "__second_codex_*" codex second-codex > "$2"' \
    _ "$SANDBOX/install \"root/second-codex-shell.zsh" "$SANDBOX/shell-snapshots/snapshot.zsh"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  env -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'source "$1"; second-codex login status' _ "$SANDBOX/shell-snapshots/snapshot.zsh"
grep -Fxq "installed-helper:login status" "$SANDBOX/helper.log"

if env -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'cd "$2"; eval "$(cat "$1")"; [[ -z ${SECOND_CODEX_SHELL_HELPER_DIR+x} ]]' \
  _ "$SANDBOX/install \"root/second-codex-shell.zsh" "$REPO_ROOT"; then
  :
else
  echo "FAIL eval-sourced helper exported an invalid helper dir"
  exit 1
fi
if env -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'cd "$2"; eval "$(cat "$1")"; second-codex login status' \
  _ "$SANDBOX/install \"root/second-codex-shell.zsh" "$REPO_ROOT" >"$SANDBOX/eval-invalid.out" 2>&1; then
  echo "FAIL eval-sourced helper unexpectedly resolved helper dir"
  exit 1
fi
grep -Fq "source second-codex-shell.zsh from its installed file path" "$SANDBOX/eval-invalid.out"

mkdir -p "$SANDBOX/eval-caller"
cat > "$SANDBOX/eval-caller/driver.zsh" <<'ZSH'
eval "$(cat "$1")"
second-codex login status
ZSH
if env -u SECOND_CODEX_SHELL_HELPER_DIR zsh "$SANDBOX/eval-caller/driver.zsh" "$SANDBOX/install \"root/second-codex-shell.zsh" \
  >"$SANDBOX/eval-caller.out" 2>&1; then
  echo "FAIL script-eval-sourced helper unexpectedly resolved helper dir"
  exit 1
fi
grep -Fq "source second-codex-shell.zsh from its installed file path" "$SANDBOX/eval-caller.out"

if env -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'source /dev/stdin < "$1"; [[ -z ${SECOND_CODEX_SHELL_HELPER_DIR+x} ]]' \
  _ "$SANDBOX/install \"root/second-codex-shell.zsh"; then
  :
else
  echo "FAIL stdin-sourced helper exported an invalid helper dir"
  exit 1
fi
if env -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'source /dev/stdin < "$1"; second-codex login status' \
  _ "$SANDBOX/install \"root/second-codex-shell.zsh" >"$SANDBOX/stdin-invalid.out" 2>&1; then
  echo "FAIL stdin-sourced helper unexpectedly resolved helper dir"
  exit 1
fi
grep -Fq "source second-codex-shell.zsh from its installed file path" "$SANDBOX/stdin-invalid.out"

: > "$SANDBOX/helper.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  env -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'source "$1"; eval "$(cat "$2")"; second-codex login status' \
    _ "$SANDBOX/install \"root/second-codex-shell.zsh" "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:login status" "$SANDBOX/helper.log"

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'primary-codex:%s account=%s active=%s\n' "$*" "${CODEX_ACCOUNT_SLOT:-missing}" "${SECOND_CODEX_ACTIVE_ACCOUNT:-missing}" >> "${SECOND_CODEX_INSTALL_HELPER_LOG:?missing log}"
SH
chmod 700 "$SANDBOX/bin/codex"
PATH="$SANDBOX/bin:$PATH" \
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -c 'source "$1"; codex login status' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "primary-codex:login status account=primary active=primary" "$SANDBOX/helper.log"

SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -fic 'source "$1"; second-codex smoke-test' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:smoke-test" "$SANDBOX/helper.log"
grep -Fq "installed-helper:_session-hint second " "$SANDBOX/helper.log"

: > "$SANDBOX/helper.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -fic 'source "$1"; second-codex --future value config get model' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:--future value config get model" "$SANDBOX/helper.log"
if grep -Fq "installed-helper:_session-hint" "$SANDBOX/helper.log"; then
  echo "FAIL setup/config command printed a session hint"
  exit 1
fi

: > "$SANDBOX/helper.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -fic 'source "$1"; second-codex exec --help' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:exec --help" "$SANDBOX/helper.log"
if grep -Fq "installed-helper:_session-hint" "$SANDBOX/helper.log"; then
  echo "FAIL help command after exec printed a session hint"
  exit 1
fi

: > "$SANDBOX/helper.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -fic 'source "$1"; second-codex upgrade' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:upgrade" "$SANDBOX/helper.log"
if grep -Fq "installed-helper:_session-hint" "$SANDBOX/helper.log"; then
  echo "FAIL upgrade command printed a session hint"
  exit 1
fi

: > "$SANDBOX/helper.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -fic 'source "$1"; second-codex --future value smoke-test' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:--future value smoke-test" "$SANDBOX/helper.log"
grep -Fq "installed-helper:_session-hint second " "$SANDBOX/helper.log"

SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/zshrc.log" \
  zsh -c 'source "$1"; second-codex login status' _ "$SANDBOX/home/.zshrc"
grep -Fxq "installed-helper:login status" "$SANDBOX/zshrc.log"

if SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/zshenv.log" \
  HOME="$SANDBOX/home" \
  ZDOTDIR="$SANDBOX/home" \
    zsh -c 'typeset -f second-codex >/dev/null'; then
  echo "FAIL second-codex helper loaded in non-interactive zsh"
  exit 1
fi

: > "$SANDBOX/zshenv.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/zshenv.log" \
HOME="$SANDBOX/home" \
ZDOTDIR="$SANDBOX/home" \
PATH="$SANDBOX/bin:$PATH" \
  env -u CODEX_ACCOUNT_SLOT -u SECOND_CODEX_ACTIVE_ACCOUNT -u SECOND_CODEX_SHELL_HELPER_DIR zsh -c 'codex exec hello'
grep -Fxq "primary-codex:exec hello account=missing active=missing" "$SANDBOX/zshenv.log"
if grep -Fq "installed-helper:_session-hint" "$SANDBOX/zshenv.log"; then
  echo "FAIL non-interactive zsh command printed a session hint"
  exit 1
fi

echo "PASS install sandbox"
