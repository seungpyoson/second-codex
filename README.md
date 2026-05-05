# Second Codex Account

`second-codex` runs Codex with the second ChatGPT subscription account while keeping the primary Codex environment as the single source of truth.

## Homes

- Primary account home: `~/.codex`
- Second account home: `~/.codex-second`
- Installed wrapper: `~/.codex-account-switch/second-codex`
- PATH entrypoint: `~/.local/bin/second-codex`

## Contract

- Primary `~/.codex` owns settings and environment: `config.toml`, MCP config, hooks, skills, plugins, rules, superpowers, and related setup files.
- Second `~/.codex-second` owns only account/runtime state: auth, sessions, history, state DB, logs, cache, temp files, and installation/global runtime state.
- Memories are shared by reference from primary:
  - `~/.codex-second/memories -> ~/.codex/memories`
  - `~/.codex-second/memories_extensions -> ~/.codex/memories_extensions`
- GitHub connector writes are governed by the connector installation, not by `CODEX_HOME`. Test connector behavior in a private sandbox repo before using it for important work.

## Environment Changes

`second-codex` automatically reroutes safe Codex setup/config mutations to the primary `~/.codex` home, then re-projects primary config into `~/.codex-second`.

Rerouted examples:

- `mcp add/remove`
- `features enable/disable`
- `plugin marketplace add/remove/upgrade`
- similar setup-changing commands

Account/auth operations remain blocked. Run account/auth changes explicitly from the intended account.

## Usage

After installation, `second-codex` is available as a PATH command from `~/.local/bin/second-codex`. New zsh sessions also load the shell helper from `~/.zshrc` for interactive session hints. For an already-open shell, run:

```bash
source ~/.codex-account-switch/second-codex-shell.zsh
```

```bash
codex
second-codex
second-codex login status
second-codex exec "Reply with exactly: second-codex ok"
```

The shell helper wraps both `codex` and `second-codex`. After an interactive, prompt, `exec`, or `resume` run exits, it prints the most recent matching session id for the current directory. Setup/status commands such as `login status`, `mcp`, `features`, and `plugin` do not print session hints.

Updates:

```bash
second-codex update
second-codex doctor
```

`install.sh` records the source checkout it was run from. `second-codex update` refreshes the installed wrapper, shell helper, manifest, PATH entrypoint, and marked `.zshrc` block from that recorded source. If the installed wrapper becomes stale, interactive runs warn once for the current source version and continue. `second-codex doctor` reports install freshness, shell-helper block status, and PATH entrypoint status.

Resume directions:

- Primary to primary: `codex resume <session_id>`
- Second to second: `second-codex resume <session_id>`
- Primary to second: `second-codex resume <session_id>`; the wrapper imports the selected primary transcript into second runtime first.
- Second to primary: `second-codex handoff <session_id> && codex resume <session_id>`

Account/usage checks:

```bash
echo "$CODEX_ACCOUNT_SLOT"
second-codex account
second-codex usage --second
second-codex usage --primary
```

`CODEX_ACCOUNT_SLOT` is set to `primary` for helper-launched `codex` sessions and `second` for `second-codex` sessions. `second-codex usage` reads the latest stored Codex `token_count` snapshot from the selected account's session transcript; it reports the most recent stored snapshot, not a live server query.

## Session Handoff

If the second ChatGPT subscription hits a usage limit, hand off the current second-account session to primary Codex:

```bash
second-codex handoff --last --cwd "$PWD"
codex resume <session_id>
```

`second-codex handoff` copies only the selected second-account session transcript and matching history entry into primary `~/.codex`. It does not copy auth, logs, state databases, caches, shell snapshots, or other second-account runtime state.

Use an explicit session id when needed:

```bash
second-codex session-id --second "$PWD"
second-codex handoff <session_id>
codex exec resume <session_id>
```

The resumed session uses the primary Codex account/provider because it is launched through `codex`, not `second-codex`.

### Cross-tool handoff (Codex ↔ Claude Code)

To continue a Codex session inside Claude Code, or a Claude Code session inside Codex, use the cross-tool converters. They translate the session into the receiving tool's native format and write it at the canonical session storage path so the receiver's native resume command picks it up.

```bash
# Started in Codex, want to continue in Claude Code:
second-codex handoff-to-claude <codex_session_id>
# Output prints the new Claude session UUID and the resume command.
claude --resume <new_uuid>

# By default, the converted Claude session is written under the source
# Codex rollout's cwd namespace. To resume from your current project cwd:
second-codex handoff-to-claude <codex_session_id> --target-cwd "$PWD"
claude --resume <new_uuid>

# If you omit --target-cwd from a different cwd, handoff-to-claude keeps the
# source-cwd default and prints stderr notes with the source cwd, current cwd,
# a --target-cwd rerun hint, and a cd <source-cwd> resume alternative.

# Started in Claude Code, want to continue in Codex:
second-codex handoff-from-claude <claude_session_id>
codex resume <new_uuid>

# `handoff-from-claude` accepts two optional Codex policy flags. Both are
# enums validated against Codex's actual schema; defaults are conservative
# (no silent permission escalation when crossing the vendor boundary):
#   --codex-approval-policy {untrusted|on-request|on-failure|never}   default: on-request
#   --codex-sandbox-policy  {read-only|workspace-write|danger-full-access}   default: read-only
# Example: convert a Claude session and resume it in Codex with no
# approval prompts and full filesystem access (matches Codex "Yolo" /
# full-access preset):
second-codex handoff-from-claude <id> --codex-approval-policy never --codex-sandbox-policy danger-full-access
```

What is preserved: text turns, tool calls and results (with linkage for the mapped pair), `cwd` context, source per-record timestamps. Image attachments do not round-trip as binary content; they become explicit omission markers. On Codex → Claude handoff, `response_item.message` is role-dispatched: assistant `output_text` and user `input_text` blocks are preserved, and duplicate `event_msg.user_message` echoes are suppressed so user prompts do not appear twice.

What is dropped on cross-vendor:

- Reasoning / thinking blocks — vendor-issued cryptographic signatures (`signature`, `encrypted_content`) cannot round-trip. Dropping them is the safe-by-construction policy: the converted session resumes successfully without them (verified by `test/e2e-resume-probe.sh`). The earlier "including them causes the receiving API to reject the turn" framing was an X-causes-Y claim observed only with X-present, never with an X-absent control, and has been withdrawn — the underlying causal mechanism remains unconfirmed.
- Claude `attachment` (hook telemetry) and `file-history-snapshot` records — the load-bearing content is already in the corresponding `tool_result` blocks.
- Codex `response_item.message` with role `developer` — these records carry source-process runtime policy and environment context (permissions, sandbox, injected project instructions). Replaying them as Claude user text would import stale source-runtime constraints into a different receiver runtime.
- Codex `agent_message` events — full-corpus scan (468 rollouts / 19,619 records) shows ~88% are duplicates of a neighboring `response_item.message` (final assistant turn) and ~12% are intermediate streaming status pings the source model emitted but never published. Adding a handler would duplicate assistant content for the bulk case.
- Codex `agent_reasoning` events — these carry plain-text reasoning and are dropped on the same cross-vendor boundary as the encrypted reasoning blocks above; reasoning content does not survive cross-vendor handoff.
- Other Codex `event_msg` metadata: `token_count`, `exec_command_end`, `patch_apply_end`, `mcp_tool_call_end`, `guardian_assessment`, `collab_*`, `web_search_end`, `context_compacted`, `thread_name_updated`, `error`, `dynamic_tool_call_request`, `dynamic_tool_call_response` (shadowed by matching `function_call_output`), `thread_rolled_back`, `item_completed`.
- Claude UI/internal records: `system`, `progress`, `last-prompt`, `permission-mode`, `queue-operation`, `pr-link`, `summary`, `custom-title`, `agent-name`.

Tool taxonomy: only `Bash` ↔ `exec_command` round-trips structurally as a native tool call. Every other tool — Codex `custom_tool_call` (e.g. `apply_patch`), `web_search_call`, `tool_search_call`, and any Claude tool other than Bash — is folded into a descriptive text block (`[Used <vendor> tool \`<name>\` with input/arguments: ...]`) so the receiving model still sees the tool history without the receiving API having to recognize a foreign tool schema. The matching tool result is rendered as `[Tool result: ...]` when the call/output linkage is intact, or `[Orphan tool result: ...]` when the call record was filtered upstream (e.g. by a `turn_aborted`) or the source has no `call_id` linking the two. Downstream consumers that grep for tool-result rows must match both prefixes. Bash → exec_command is also slightly lossy: Claude's Bash input has no per-call workdir field, so every converted exec_command call inherits the session-level `cwd`.

Genuinely unknown record types (a future Codex/Claude schema addition not in the documented drop-list) emit a stderr warning and are dropped, surfacing schema drift instead of letting it become silent loss.

Both converters require `python3`. Converters write a fresh file under a new UUID and never mutate the source session, so any acceptance / rejection by the receiver is contained to the converted file. The exact validation behavior on a deliberately malformed rollout is the receiver's contract and is not exercised by this repo's tests.

End-to-end resume acceptance has been verified manually with both `claude --resume <new_uuid>` and `codex exec resume <new_uuid>`: a marker placed in a *prior turn* of the source session is recalled by the receiving model after conversion, which only happens if the receiver actually loaded the converted history into context. The probe lives in `test/e2e-resume-probe.sh` and is not part of the standard `bash test/converter-sandbox.sh` suite because it requires live API access.

The Claude `~/.claude/projects/<encoded-cwd>/` encoding rule was reverse-engineered from real local sessions: realpath the cwd, then replace every non-`[A-Za-z0-9-]` character with `-`. On macOS this means `/tmp/foo` becomes `-private-tmp-foo` (because `/tmp` symlinks to `/private/tmp`), `~/.claude` becomes `-Users-<u>--claude`, and `Application Support` becomes `Application-Support`. An earlier rule that only replaced `/` with `-` left converted sessions invisible to `claude --resume` for any source path traversing a macOS symlink.

## Security Notes

- `second-codex` is account/config isolation, not an OS security sandbox.
- Memories are shared with primary Codex; do not use `second-codex` for memory-private work.
- Session handoff intentionally copies the selected second-account transcript into primary Codex so primary can resume it.
- GitHub connector writes use the GitHub connector installation; avoid destructive GitHub actions unless explicitly intended.
- Safe setup/config commands are rerouted to primary `~/.codex`; account/auth commands are blocked.
- The subprocess shim is generated under a user-specific temp path such as `/tmp/second-codex-shim-501` with owner checks and restrictive permissions.
- `ownership-manifest.txt` is the source of truth for account/runtime and environment ownership. Sync fails closed when either account home has unknown top-level entries.
- After Codex upgrades, run `second-codex doctor` to detect new top-level Codex state that needs classification.

## Doctor

Run:

```bash
second-codex doctor
```

The doctor checks account homes, unknown top-level entries, shared memory symlinks, shim safety, and account/auth command blocking. By default it reports only whether accounts are logged in. Set `SECOND_CODEX_DOCTOR_SHOW_EMAIL=1` for local debugging if you need to display account emails.

## Rollback

Remove the shell helper line from `~/.zshenv` and `~/.zshrc`, then remove the second-account files if no longer needed:

```bash
rm -f ~/.codex-account-switch/second-codex
rm -rf ~/.codex-second
```

Do not remove `~/.codex`; it is the primary account environment.
