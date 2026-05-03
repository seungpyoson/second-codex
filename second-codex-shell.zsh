# Codex second account convenience command.
# Primary ~/.codex remains the source of truth for settings/environment.
__second_codex_helper_dir() {
  local helper_path="${(%):-%x}"
  printf '%s\n' "${helper_path:A:h}"
}

__second_codex_first_command() {
  local args=("$@")
  local i=1
  while (( i <= ${#args[@]} )); do
    case "${args[$i]}" in
      --help|-h|--version|-V)
        printf '%s\n' "${args[$i]}"
        return
        ;;
      --*=*)
        i=$((i + 1))
        ;;
      --)
        i=$((i + 1))
        break
        ;;
      -*)
        case "${args[$i]}" in
          -c|--config|-m|--model|-p|--profile|-s|--sandbox|-C|--cd|-a|--ask-for-approval|--remote|--remote-auth-token-env|--add-dir|--local-provider|--download-url|--enable|--disable|-i|--image)
            i=$((i + 2))
            ;;
          *)
            i=$((i + 1))
            ;;
        esac
        ;;
      *)
        break
        ;;
    esac
  done
  printf '%s\n' "${args[$i]:-}"
}

__second_codex_should_print_session_hint() {
  local command="$(__second_codex_first_command "$@")"
  case "$command" in
    ""|exec|resume)
      return 0
      ;;
    --help|-h|--version|-V|_session-hint|doctor|handoff|session-id|login|logout|mcp|features|plugin|plugins|skill|skills|app|apps|config|configure|trust|untrust|update)
      return 1
      ;;
  esac

  local arg
  for arg in "$@"; do
    case "$arg" in
      _session-hint|doctor|handoff|session-id|login|logout|mcp|features|plugin|plugins|skill|skills|app|apps|config|configure|trust|untrust|update)
        return 1
        ;;
    esac
  done

  # Treat a non-command first positional value as a prompt.
  return 0
}

__second_codex_session_hint() {
  local account="$1"
  local helper_dir="$(__second_codex_helper_dir)"
  "$helper_dir/second-codex" _session-hint "$account" "$PWD" 2>/dev/null || true
}

codex() {
  command codex "$@"
  local rc=$?
  if (( rc == 0 )) && __second_codex_should_print_session_hint "$@"; then
    __second_codex_session_hint primary
  fi
  return $rc
}

second-codex() {
  local helper_dir="$(__second_codex_helper_dir)"
  "$helper_dir/second-codex" "$@"
  local rc=$?
  if (( rc == 0 )) && __second_codex_should_print_session_hint "$@"; then
    __second_codex_session_hint second
  fi
  return $rc
}
