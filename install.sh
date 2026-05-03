#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="${SECOND_CODEX_SWITCH_ROOT:-$HOME/.codex-account-switch}"
mkdir -p "$INSTALL_ROOT"
cp "$(dirname "$0")/second-codex" "$INSTALL_ROOT/second-codex"
cp "$(dirname "$0")/second-codex-shell.zsh" "$INSTALL_ROOT/second-codex-shell.zsh"
cp "$(dirname "$0")/ownership-manifest.txt" "$INSTALL_ROOT/ownership-manifest.txt"
cp "$(dirname "$0")/README.md" "$INSTALL_ROOT/README.md"
chmod +x "$INSTALL_ROOT/second-codex"

ZSHRC="${ZSHRC:-$HOME/.zshrc}"
LINE="source $INSTALL_ROOT/second-codex-shell.zsh"
if [ -f "$ZSHRC" ] && grep -Fxq "$LINE" "$ZSHRC"; then
  echo "second-codex shell helper already sourced in $ZSHRC"
else
  printf '\n%s\n' "$LINE" >> "$ZSHRC"
  echo "Added shell helper source line to $ZSHRC"
fi

echo "Installed second-codex to $INSTALL_ROOT"
echo "Open a new shell or run: source $INSTALL_ROOT/second-codex-shell.zsh"
