#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="${SECOND_CODEX_SWITCH_ROOT:-$HOME/.codex-account-switch}"
PRIMARY_HOME="${CODEX_A_HOME:-$HOME/.codex}"
SECOND_HOME="${SECOND_CODEX_HOME:-$HOME/.codex-second}"

shell_quote() {
  local value="${1//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

mkdir -p "$INSTALL_ROOT"
cp "$(dirname "$0")/second-codex" "$INSTALL_ROOT/second-codex"
cp "$(dirname "$0")/second-codex-shell.zsh" "$INSTALL_ROOT/second-codex-shell.zsh"
cp "$(dirname "$0")/ownership-manifest.txt" "$INSTALL_ROOT/ownership-manifest.txt"
cp "$(dirname "$0")/README.md" "$INSTALL_ROOT/README.md"
chmod +x "$INSTALL_ROOT/second-codex"

link_shared_path() {
  local name="$1"
  local target="$PRIMARY_HOME/$name"
  local link="$SECOND_HOME/$name"

  mkdir -p "$target" "$SECOND_HOME"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    return 0
  fi
  if [[ -e "$link" || -L "$link" ]]; then
    echo "Refusing to replace existing $link; move it aside, then rerun install." >&2
    return 73
  fi
  ln -s "$target" "$link"
}

link_shared_path memories
link_shared_path memories_extensions

ZSHRC="${ZSHRC:-$HOME/.zshrc}"
LINE="source $(shell_quote "$INSTALL_ROOT/second-codex-shell.zsh")"
if [ -f "$ZSHRC" ] && grep -Fxq "$LINE" "$ZSHRC"; then
  echo "second-codex shell helper already sourced in $ZSHRC"
else
  printf '\n%s\n' "$LINE" >> "$ZSHRC"
  echo "Added shell helper source line to $ZSHRC"
fi

echo "Installed second-codex to $INSTALL_ROOT"
echo "Open a new shell or run: source $INSTALL_ROOT/second-codex-shell.zsh"
