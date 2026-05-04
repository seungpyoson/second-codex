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
  zsh -fic 'source "$1"; second-codex --future value smoke-test' _ "$SANDBOX/install \"root/second-codex-shell.zsh"
grep -Fxq "installed-helper:--future value smoke-test" "$SANDBOX/helper.log"
grep -Fq "installed-helper:_session-hint second " "$SANDBOX/helper.log"

SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/zshrc.log" \
  zsh -c 'source "$1"; second-codex login status' _ "$SANDBOX/home/.zshrc"
grep -Fxq "installed-helper:login status" "$SANDBOX/zshrc.log"

SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/zshenv.log" \
HOME="$SANDBOX/home" \
ZDOTDIR="$SANDBOX/home" \
  zsh -c 'second-codex login status'
grep -Fxq "installed-helper:login status" "$SANDBOX/zshenv.log"

: > "$SANDBOX/zshenv.log"
SECOND_CODEX_INSTALL_HELPER_LOG="$SANDBOX/zshenv.log" \
HOME="$SANDBOX/home" \
ZDOTDIR="$SANDBOX/home" \
PATH="$SANDBOX/bin:$PATH" \
  zsh -c 'codex exec hello'
grep -Fxq "primary-codex:exec hello account=primary active=primary" "$SANDBOX/zshenv.log"
if grep -Fq "installed-helper:_session-hint" "$SANDBOX/zshenv.log"; then
  echo "FAIL non-interactive zsh command printed a session hint"
  exit 1
fi

echo "PASS install sandbox"
