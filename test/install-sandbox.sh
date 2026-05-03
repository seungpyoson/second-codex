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
"$REPO_ROOT/install.sh" >"$SANDBOX/install.out"

test -x "$SANDBOX/install \"root/second-codex"
test -f "$SANDBOX/install \"root/ownership-manifest.txt"
test -L "$SANDBOX/home/.codex-second/memories"
test -L "$SANDBOX/home/.codex-second/memories_extensions"
test "$(readlink "$SANDBOX/home/.codex-second/memories")" = "$SANDBOX/home/.codex/memories"
test "$(readlink "$SANDBOX/home/.codex-second/memories_extensions")" = "$SANDBOX/home/.codex/memories_extensions"

cat > "$SANDBOX/install \"root/second-codex" <<'SH'
#!/usr/bin/env bash
printf 'installed-helper:%s\n' "$*" >> "${SECOND_CODEX_INSTALL_HELPER_LOG:?missing log}"
SH
chmod 700 "$SANDBOX/install \"root/second-codex"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -c 'source "$1"; second-codex login status' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:login status" "$SANDBOX/helper.log"

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'primary-codex:%s\n' "$*" >> "${SECOND_CODEX_INSTALL_HELPER_LOG:?missing log}"
SH
chmod 700 "$SANDBOX/bin/codex"
PATH="$SANDBOX/bin:$PATH" \
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -c 'source "$1"; codex login status' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "primary-codex:login status" "$SANDBOX/helper.log"

SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -c 'source "$1"; second-codex smoke-test' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:smoke-test" "$SANDBOX/helper.log"
grep -Fq "installed-helper:_session-hint second " "$SANDBOX/helper.log"

: > "$SANDBOX/helper.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/helper.log" \
  zsh -c 'source "$1"; second-codex --future value config get model' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:--future value config get model" "$SANDBOX/helper.log"
if grep -Fq "installed-helper:_session-hint" "$SANDBOX/helper.log"; then
  echo "FAIL setup/config command printed a session hint"
  exit 1
fi

SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/zshrc.log" \
  zsh -c 'source "$1"; second-codex login status' _ "$SANDBOX/home/.zshrc"
grep -Fxq "installed-helper:login status" "$SANDBOX/zshrc.log"

echo "PASS install sandbox"
