# Codex second account convenience command.
# Primary ~/.codex remains the source of truth for settings/environment.
() {
  local source_path="${(%):-%x}"
  # Claude/Codex shell snapshots serialize functions into snapshot files. A
  # call-time %x expansion then points at the snapshot, so embed the install
  # directory into the helper function body at source time.
  if [[ -f "$source_path" && "${source_path:t}" == "second-codex-shell.zsh" ]]; then
    local helper_dir="${source_path:A:h}"
    eval "__second_codex_helper_dir() { printf '%s\\n' ${(qqq)helper_dir}; }"
  elif ! (( $+functions[__second_codex_helper_dir] )); then
    __second_codex_helper_dir() {
      echo "second-codex shell helper directory is unavailable; source second-codex-shell.zsh from its installed file path" >&2
      return 64
    }
  fi
}

__second_codex_should_print_session_hint() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help|-h|--version|-V)
        return 1
        ;;
    esac
  done

  for arg in "$@"; do
    case "$arg" in
      exec|resume)
        return 0
        ;;
      _session-hint|doctor|handoff|session-id|login|logout|mcp|features|plugin|plugins|skill|skills|app|apps|config|configure|trust|untrust|update|upgrade)
        return 1
        ;;
    esac
  done

  # Treat a non-command first positional value as a prompt.
  return 0
}

__second_codex_session_hint() {
  local account="$1"
  local helper_dir
  helper_dir="$(__second_codex_helper_dir)" || return $?
  "$helper_dir/second-codex" _session-hint "$account" "$PWD" 2>/dev/null || true
}

codex() {
  CODEX_ACCOUNT_SLOT=primary SECOND_CODEX_ACTIVE_ACCOUNT=primary command codex "$@"
  local rc=$?
  if [[ -o interactive ]] && (( rc == 0 )) && __second_codex_should_print_session_hint "$@"; then
    __second_codex_session_hint primary
  fi
  return $rc
}

second-codex() {
  local helper_dir
  helper_dir="$(__second_codex_helper_dir)" || return $?
  "$helper_dir/second-codex" "$@"
  local rc=$?
  if [[ -o interactive ]] && (( rc == 0 )) && __second_codex_should_print_session_hint "$@"; then
    __second_codex_session_hint second
  fi
  return $rc
}
