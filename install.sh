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
mkdir -p "$INSTALL_ROOT/lib"
cp "$(dirname "$0")/lib/session_convert.py" "$INSTALL_ROOT/lib/session_convert.py"
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

LINE="source $(shell_quote "$INSTALL_ROOT/second-codex-shell.zsh")"
LEGACY_LINE="source $INSTALL_ROOT/second-codex-shell.zsh"
MARKER_BEGIN="# >>> second-codex shell helper >>>"
MARKER_END="# <<< second-codex shell helper <<<"
DEFAULT_HOME_LINE='$HOME/.codex-account-switch/second-codex-shell.zsh'

marked_block_status() {
  local file="$1"
  local default_home_ok=0
  if [[ "$INSTALL_ROOT" == "$HOME/.codex-account-switch" ]]; then
    default_home_ok=1
  fi
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v line="$LINE" -v legacy="$LEGACY_LINE" \
    -v default_home_line="$DEFAULT_HOME_LINE" -v default_home_ok="$default_home_ok" '
    $0 == begin { in_block = 1; saw_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block && ($0 == line || $0 == legacy || (default_home_ok && index($0, default_home_line))) { current = 1 }
    END {
      if (current) {
        exit 0
      }
      if (saw_block) {
        exit 2
      }
      exit 1
    }
  ' "$file"
}

replace_marked_block() {
  local file="$1"
  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/second-codex-zshrc.XXXXXX")" || return $?
  if ! awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v line="$LINE" '
    $0 == begin && !replaced {
      print begin
      print line
      print end
      in_block = 1
      replaced = 1
      next
    }
    in_block && $0 == end { in_block = 0; next }
    in_block { next }
    { print }
    END { if (!replaced) exit 1 }
  ' "$file" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  if ! cat "$tmp_file" > "$file"; then
    rm -f "$tmp_file"
    return 73
  fi
  rm -f "$tmp_file"
}

ensure_source_line() {
  local file="$1"
  local block_status=1
  if [ -f "$file" ]; then
    set +e
    marked_block_status "$file"
    block_status=$?
    set -e
  fi
  if [ "$block_status" -eq 0 ]; then
    echo "second-codex shell helper already sourced in marked block in $file"
  elif [ -f "$file" ] && { grep -Fxq "$LINE" "$file" || grep -Fxq "$LEGACY_LINE" "$file"; }; then
    echo "second-codex shell helper already sourced in $file"
  elif [ -L "$file" ]; then
    echo "Refusing to edit symlink-managed shell config: $file -> $(readlink "$file")" >&2
    echo "Add this block to the real config file yourself:" >&2
    printf '%s\n%s\n%s\n' "$MARKER_BEGIN" "$LINE" "$MARKER_END" >&2
    return 73
  elif [ "$block_status" -eq 2 ]; then
    replace_marked_block "$file" || return $?
    echo "Updated marked shell helper source block in $file"
  else
    local parent_dir
    parent_dir="$(dirname "$file")"
    if [ ! -d "$parent_dir" ]; then
      echo "Refusing to edit shell config because its parent directory does not exist: $parent_dir" >&2
      return 73
    fi
    printf '\n%s\n%s\n%s\n' "$MARKER_BEGIN" "$LINE" "$MARKER_END" >> "$file"
    echo "Added marked shell helper source block to $file"
  fi
}

ZSHRC="${ZSHRC:-$HOME/.zshrc}"
ensure_source_line "$ZSHRC"

echo "Installed second-codex to $INSTALL_ROOT"
echo "New zsh sessions can now use second-codex from any directory."
echo "For this already-open shell, run: source $INSTALL_ROOT/second-codex-shell.zsh"
