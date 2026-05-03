# Codex second account convenience command.
# Primary ~/.codex remains the source of truth for settings/environment.
second-codex() {
  local helper_path="${(%):-%x}"
  local helper_dir="${helper_path:A:h}"
  "$helper_dir/second-codex" "$@"
}
