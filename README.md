# Second Codex Account

`second-codex` runs Codex with the second ChatGPT subscription account while keeping the primary Codex environment as the single source of truth.

## Homes

- Primary account home: `~/.codex`
- Second account home: `~/.codex-second`
- Wrapper: `~/.codex-account-switch/second-codex`

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

After loading the shell helper:

```bash
codex
second-codex
second-codex login status
second-codex exec "Reply with exactly: second-codex ok"
```

The shell helper wraps both `codex` and `second-codex`. After an interactive, prompt, `exec`, or `resume` run exits, it prints the most recent matching session id for the current directory. Setup/status commands such as `login status`, `mcp`, `features`, and `plugin` do not print session hints.

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

Remove the shell helper line from `~/.zshrc`, then remove the second-account files if no longer needed:

```bash
rm -f ~/.codex-account-switch/second-codex
rm -rf ~/.codex-second
```

Do not remove `~/.codex`; it is the primary account environment.
