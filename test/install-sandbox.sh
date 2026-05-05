#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-install-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

SAME_HOME="$SANDBOX/same-home"
mkdir -p "$SAME_HOME"
if HOME="$SAME_HOME" \
  SECOND_CODEX_SWITCH_ROOT="$SAME_HOME/install-root/" \
  CODEX_A_HOME="$SAME_HOME/codex" \
  SECOND_CODEX_HOME="$SAME_HOME/codex/" \
  ZSHRC="$SAME_HOME/.zshrc" \
  "$REPO_ROOT/install.sh" >"$SANDBOX/same-home-install.out" 2>&1; then
  echo "FAIL installer allowed primary and second CODEX_HOME to be the same"
  cat "$SANDBOX/same-home-install.out"
  exit 1
fi
grep -Fq "refused to install because primary and second CODEX_HOME are the same" "$SANDBOX/same-home-install.out"
if [[ -e "$SAME_HOME/install-root/second-codex" ]]; then
  echo "FAIL installer copied files before refusing identical CODEX_HOME values"
  exit 1
fi

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
grep -Fxq "CODEX_ACCOUNT_SLOT=second SECOND_CODEX_ACTIVE_ACCOUNT=second SECOND_CODEX_SWITCH_ROOT='$SANDBOX/install \"root' exec '$SANDBOX/install \"root/second-codex' \"\$@\"" "$SANDBOX/home/.local/bin/second-codex" || {
  echo "FAIL PATH entrypoint did not contain the expected second-account wrapper exec"
  cat "$SANDBOX/home/.local/bin/second-codex"
  exit 1
}
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
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
SECOND_CODEX_SWITCH_REAL_CODEX="$SANDBOX/mock-unused-codex" \
  "$SANDBOX/home/.local/bin/second-codex" account >"$SANDBOX/path-entrypoint.out"
grep -Fq "account_slot=second" "$SANDBOX/path-entrypoint.out" || {
  echo "FAIL PATH entrypoint did not establish second account context"
  cat "$SANDBOX/path-entrypoint.out"
  exit 1
}
grep -Fq "codex_home=$SANDBOX/home/.codex-second" "$SANDBOX/path-entrypoint.out" || {
  echo "FAIL PATH entrypoint did not infer second CODEX_HOME"
  cat "$SANDBOX/path-entrypoint.out"
  exit 1
}

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
warn_mode="$(stat -f '%Lp' "$SANDBOX/install \"root/.last-stale-warning" 2>/dev/null || stat -c '%a' "$SANDBOX/install \"root/.last-stale-warning")"
if [[ "$warn_mode" != "600" ]]; then
  echo "FAIL stale warning marker was not written with private permissions: $warn_mode"
  exit 1
fi
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
FAKE_DATE_BIN="$SANDBOX/fake-date-bin"
mkdir -p "$FAKE_DATE_BIN"
cat > "$FAKE_DATE_BIN/date" <<'SH'
#!/usr/bin/env bash
exit 99
SH
chmod +x "$FAKE_DATE_BIN/date"
HOME="$SANDBOX/home" \
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/install \"root" \
CODEX_A_HOME="$SANDBOX/home/.codex" \
SECOND_CODEX_HOME="$SANDBOX/home/.codex-second" \
ZSHRC="$SANDBOX/home/.zshrc" \
PATH="$FAKE_DATE_BIN:$PATH" \
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

COMMENTED_HOME="$SANDBOX/commented-home"
mkdir -p "$COMMENTED_HOME"
cat > "$COMMENTED_HOME/.zshrc" <<'ZSHRC'
# >>> second-codex shell helper >>>
# [[ -r "$HOME/.codex-account-switch/second-codex-shell.zsh" ]] && source "$HOME/.codex-account-switch/second-codex-shell.zsh"
# <<< second-codex shell helper <<<
ZSHRC
HOME="$COMMENTED_HOME" \
CODEX_A_HOME="$COMMENTED_HOME/.codex" \
SECOND_CODEX_HOME="$COMMENTED_HOME/.codex-second" \
ZSHRC="$COMMENTED_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/commented-install.out"
if grep -Fxq '# [[ -r "$HOME/.codex-account-switch/second-codex-shell.zsh" ]] && source "$HOME/.codex-account-switch/second-codex-shell.zsh"' "$COMMENTED_HOME/.zshrc"; then
  echo "FAIL installer accepted commented-out helper source line as active"
  cat "$COMMENTED_HOME/.zshrc"
  exit 1
fi
grep -Fxq "source '$COMMENTED_HOME/.codex-account-switch/second-codex-shell.zsh'" "$COMMENTED_HOME/.zshrc"

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

DUP_HOME="$SANDBOX/duplicate-block-home"
mkdir -p "$DUP_HOME"
cat > "$DUP_HOME/.zshrc" <<ZSHRC
# >>> second-codex shell helper >>>
source '$DUP_HOME/old-root/second-codex-shell.zsh'
# <<< second-codex shell helper <<<
export KEEP_ONE=1
# >>> second-codex shell helper >>>
source '$DUP_HOME/older-root/second-codex-shell.zsh'
# <<< second-codex shell helper <<<
export KEEP_TWO=1
ZSHRC
HOME="$DUP_HOME" \
SECOND_CODEX_SWITCH_ROOT="$DUP_HOME/new-root" \
CODEX_A_HOME="$DUP_HOME/.codex" \
SECOND_CODEX_HOME="$DUP_HOME/.codex-second" \
ZSHRC="$DUP_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/duplicate-block-install.out"
grep -Fxq "export KEEP_ONE=1" "$DUP_HOME/.zshrc"
grep -Fxq "export KEEP_TWO=1" "$DUP_HOME/.zshrc"
if [ "$(grep -c "# >>> second-codex shell helper >>>" "$DUP_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer did not collapse duplicate helper blocks"
  cat "$DUP_HOME/.zshrc"
  exit 1
fi
if [ "$(grep -c "second-codex-shell.zsh" "$DUP_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer left duplicate helper source lines"
  cat "$DUP_HOME/.zshrc"
  exit 1
fi
grep -Fxq "source '$DUP_HOME/new-root/second-codex-shell.zsh'" "$DUP_HOME/.zshrc"

CURRENT_DUP_HOME="$SANDBOX/current-duplicate-block-home"
mkdir -p "$CURRENT_DUP_HOME"
cat > "$CURRENT_DUP_HOME/.zshrc" <<ZSHRC
# >>> second-codex shell helper >>>
source '$CURRENT_DUP_HOME/new-root/second-codex-shell.zsh'
# <<< second-codex shell helper <<<
export KEEP_CURRENT_DUP=1
# >>> second-codex shell helper >>>
source '$CURRENT_DUP_HOME/old-root/second-codex-shell.zsh'
# <<< second-codex shell helper <<<
ZSHRC
HOME="$CURRENT_DUP_HOME" \
SECOND_CODEX_SWITCH_ROOT="$CURRENT_DUP_HOME/new-root" \
CODEX_A_HOME="$CURRENT_DUP_HOME/.codex" \
SECOND_CODEX_HOME="$CURRENT_DUP_HOME/.codex-second" \
ZSHRC="$CURRENT_DUP_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/current-duplicate-block-install.out"
grep -Fxq "export KEEP_CURRENT_DUP=1" "$CURRENT_DUP_HOME/.zshrc"
if [ "$(grep -c "# >>> second-codex shell helper >>>" "$CURRENT_DUP_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer skipped duplicate helper collapse when one block was already current"
  cat "$CURRENT_DUP_HOME/.zshrc"
  exit 1
fi
if [ "$(grep -c "second-codex-shell.zsh" "$CURRENT_DUP_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer left duplicate helper source lines when one block was already current"
  cat "$CURRENT_DUP_HOME/.zshrc"
  exit 1
fi
grep -Fxq "source '$CURRENT_DUP_HOME/new-root/second-codex-shell.zsh'" "$CURRENT_DUP_HOME/.zshrc"

NESTED_DUP_HOME="$SANDBOX/nested-duplicate-block-home"
mkdir -p "$NESTED_DUP_HOME"
cat > "$NESTED_DUP_HOME/.zshrc" <<ZSHRC
# >>> second-codex shell helper >>>
# >>> second-codex shell helper >>>
source '$NESTED_DUP_HOME/old-root/second-codex-shell.zsh'
# <<< second-codex shell helper <<<
# <<< second-codex shell helper <<<
export KEEP_NESTED_DUP=1
ZSHRC
HOME="$NESTED_DUP_HOME" \
SECOND_CODEX_SWITCH_ROOT="$NESTED_DUP_HOME/new-root" \
CODEX_A_HOME="$NESTED_DUP_HOME/.codex" \
SECOND_CODEX_HOME="$NESTED_DUP_HOME/.codex-second" \
ZSHRC="$NESTED_DUP_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/nested-duplicate-block-install.out"
grep -Fxq "export KEEP_NESTED_DUP=1" "$NESTED_DUP_HOME/.zshrc"
if [ "$(grep -c "# >>> second-codex shell helper >>>" "$NESTED_DUP_HOME/.zshrc")" -ne 1 ] \
  || [ "$(grep -c "# <<< second-codex shell helper <<<" "$NESTED_DUP_HOME/.zshrc")" -ne 1 ]; then
  echo "FAIL installer leaked nested duplicate helper markers"
  cat "$NESTED_DUP_HOME/.zshrc"
  exit 1
fi
grep -Fxq "source '$NESTED_DUP_HOME/new-root/second-codex-shell.zsh'" "$NESTED_DUP_HOME/.zshrc"

MALFORMED_HOME="$SANDBOX/malformed-home"
mkdir -p "$MALFORMED_HOME"
cat > "$MALFORMED_HOME/.zshrc" <<ZSHRC
# >>> second-codex shell helper >>>
source '$MALFORMED_HOME/old-root/second-codex-shell.zsh'
export KEEP_ME=1
ZSHRC
HOME="$MALFORMED_HOME" \
SECOND_CODEX_SWITCH_ROOT="$MALFORMED_HOME/new-root" \
CODEX_A_HOME="$MALFORMED_HOME/.codex" \
SECOND_CODEX_HOME="$MALFORMED_HOME/.codex-second" \
ZSHRC="$MALFORMED_HOME/.zshrc" \
"$REPO_ROOT/install.sh" >"$SANDBOX/malformed-install.out" 2>&1 && {
  echo "FAIL installer accepted malformed helper block"
  cat "$SANDBOX/malformed-install.out"
  exit 1
}
grep -Fxq "export KEEP_ME=1" "$MALFORMED_HOME/.zshrc"
grep -Fq "Refusing to edit malformed second-codex shell helper block" "$SANDBOX/malformed-install.out"
if grep -Fxq "source '$MALFORMED_HOME/new-root/second-codex-shell.zsh'" "$MALFORMED_HOME/.zshrc"; then
  echo "FAIL installer appended a new helper source after a malformed helper block"
  cat "$MALFORMED_HOME/.zshrc"
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
