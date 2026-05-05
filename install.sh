#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="${SECOND_CODEX_SWITCH_ROOT:-$HOME/.codex-account-switch}"
PRIMARY_HOME="${CODEX_A_HOME:-$HOME/.codex}"
SECOND_HOME="${SECOND_CODEX_HOME:-$HOME/.codex-second}"
SOURCE_ROOT="$(cd "$(dirname "$0")" && pwd)"
PATH_DIR="${SECOND_CODEX_PATH_DIR:-$HOME/.local/bin}"

shell_quote() {
  local value="${1//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

install_file() {
  local src="$1"
  local dest="$2"
  local parent base tmp mode
  parent="$(dirname "$dest")"
  base="$(basename "$dest")"
  mkdir -p "$parent"
  mode="$(stat -f '%Lp' "$src" 2>/dev/null || stat -c '%a' "$src")" || return $?
  tmp="$(umask 077; mktemp "$parent/.${base}.second-codex.XXXXXX")" || return $?
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp"
    return 73
  fi
  if ! chmod "$mode" "$tmp"; then
    rm -f "$tmp"
    return 73
  fi
  if ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    return 73
  fi
}

install_manifest() {
  local src="$1"
  local dest="$2"
  local backup
  if [[ -f "$dest" ]] && ! cmp -s "$src" "$dest"; then
    backup="$dest.local-backup-$(date +%Y%m%d%H%M%S)"
    if [[ -e "$backup" ]]; then
      backup="$backup.$$"
    fi
    install_file "$dest" "$backup" || return $?
  fi
  install_file "$src" "$dest"
}

mkdir -p "$INSTALL_ROOT"
install_file "$SOURCE_ROOT/second-codex" "$INSTALL_ROOT/second-codex"
install_file "$SOURCE_ROOT/second-codex-shell.zsh" "$INSTALL_ROOT/second-codex-shell.zsh"
install_manifest "$SOURCE_ROOT/ownership-manifest.txt" "$INSTALL_ROOT/ownership-manifest.txt"
install_file "$SOURCE_ROOT/README.md" "$INSTALL_ROOT/README.md"
mkdir -p "$INSTALL_ROOT/lib"
install_file "$SOURCE_ROOT/lib/session_convert.py" "$INSTALL_ROOT/lib/session_convert.py"
chmod +x "$INSTALL_ROOT/second-codex"
printf '%s\n' "$SOURCE_ROOT" > "$INSTALL_ROOT/source-root"

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

ensure_path_entrypoint() {
  local target="$PATH_DIR/second-codex"
  local tmp_entrypoint
  mkdir -p "$PATH_DIR"
  if [[ -e "$target" && ! -f "$target" || -L "$target" ]]; then
    echo "Refusing to replace unsafe PATH entrypoint: $target" >&2
    return 73
  fi
  tmp_entrypoint="$(umask 077; mktemp "$PATH_DIR/second-codex.XXXXXX")" || return $?
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'SECOND_CODEX_SWITCH_ROOT=%s exec %s "$@"\n' "$(shell_quote "$INSTALL_ROOT")" "$(shell_quote "$INSTALL_ROOT/second-codex")"
  } > "$tmp_entrypoint" || { rm -f "$tmp_entrypoint"; return 73; }
  chmod 700 "$tmp_entrypoint"
  mv "$tmp_entrypoint" "$target"
}

ensure_path_entrypoint

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
  if [[ -L "$file" ]]; then
    return 73
  fi
  local parent_dir base_name tmp_file mode
  parent_dir="$(dirname "$file")"
  base_name="$(basename "$file")"
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file")" || return $?
  tmp_file="$(umask 077; mktemp "$parent_dir/.${base_name}.second-codex.XXXXXX")" || return $?
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
  if ! chmod "$mode" "$tmp_file"; then
    rm -f "$tmp_file"
    return 73
  fi
  if ! mv "$tmp_file" "$file"; then
    rm -f "$tmp_file"
    return 73
  fi
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
echo "Installed PATH entrypoint to $PATH_DIR/second-codex"
echo "New zsh sessions can now use second-codex from any directory."
echo "For non-interactive shells, ensure $PATH_DIR is on PATH."
echo "For this already-open shell, run: source $INSTALL_ROOT/second-codex-shell.zsh"
