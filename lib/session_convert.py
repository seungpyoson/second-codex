#!/usr/bin/env python3
"""Bidirectional session-state converters between Claude Code and Codex CLI.

Reads a source-format session JSONL and emits the equivalent target-format
JSONL at the target tool's canonical session path. The target tool's native
resume command (`claude --resume <uuid>` or `codex resume <uuid>`) then loads
the converted session as if it were native.

Subcommands:
  codex-to-claude <codex-uuid> [--target-cwd <path>]
  claude-to-codex <claude-uuid> [--target-cwd <path>]

Each prints the new session UUID on success; resume the converted session
with the target tool's native command.

Conversion semantics:

- Text turns translate role-for-role (user / assistant).
- Codex `response_item.message` is role-dispatched: assistant `output_text`
  and user `input_text` blocks are load-bearing conversation turns.
  Adjacent `event_msg.user_message` records are compatibility echoes of the
  same user text and are suppressed to avoid duplicate prompts. Developer
  role messages carry runtime policy/environment context from the source
  process and are intentionally not portable across vendors.
- Tool calls round-trip structurally only when both sides recognize the
  tool; the cross-vendor mapping is deliberately narrow (Bash <->
  exec_command). Unmapped tools (including Codex `custom_tool_call`,
  `web_search_call`, `tool_search_call`, and any Claude tool other than
  Bash) fold into descriptive text blocks so the receiving model still
  sees the prior tool history without depending on the receiving API to
  recognize a foreign tool name.
- Reasoning / thinking blocks are dropped on cross-vendor handoff. Both
  vendors store reasoning with vendor-issued cryptographic signatures
  (Claude `signature`, Codex `encrypted_content`) that the receiving
  vendor cannot validate. Dropping is the safe-by-construction policy:
  the converted session resumes successfully without them (verified by
  `test/e2e-resume-probe.sh`). The earlier "including them causes the
  receiving API to reject the turn" framing was withdrawn — it was an
  X-causes-Y claim observed only with X-present, never with an X-absent
  control, so the underlying causal mechanism remains unconfirmed.
- Codex `turn_aborted` markers cause the response_items emitted since the
  most recent `task_started` to be discarded, matching the source model's
  view that those items were never committed.
- Codex `agent_message` events are dropped intentionally: full-corpus scan
  (468 rollouts / 19619 agent_message records, 2026-05-04 local data) shows
  ~88% are duplicates of a neighboring `response_item.message` (final
  assistant turn) and ~12% are intermediate streaming pings the source
  model emitted during a turn but never published. Adding a handler would
  duplicate the bulk of assistant content. Codex `agent_reasoning` records
  are also dropped: they carry plain-text reasoning and are dropped on the
  same cross-vendor boundary as the encrypted reasoning blocks above —
  reasoning content does not survive cross-vendor handoff. Other event_msg
  types (`token_count`, `exec_command_end`, `patch_apply_end`,
  `mcp_tool_call_end`, `guardian_assessment`, `collab_*`, `web_search_end`,
  `context_compacted`, `thread_name_updated`, `error`,
  `dynamic_tool_call_request`, `dynamic_tool_call_response` (shadowed by
  matching `function_call_output`), `thread_rolled_back`, `item_completed`)
  are streaming/metadata or shadowed-content not load-bearing for resume
  context.
- Claude `attachment` (hook telemetry) and `file-history-snapshot` records
  are dropped: their information is already present in the corresponding
  `tool_result` content (what the source model actually saw), or is
  Claude Code-internal bookkeeping not load-bearing for conversation
  continuation. Claude `system`, `progress`, `last-prompt`, `permission-mode`,
  `queue-operation`, `pr-link`, `summary`, `custom-title`, `agent-name`
  records are also dropped (UI/internal bookkeeping).
- Bash tool calls translate to/from Codex `exec_command`, but per-call
  workdir is lossy in the Claude→Codex direction: Claude's Bash tool input
  has no per-call workdir field, so every converted exec_command call
  inherits the session-level `cwd`. Real per-call workdirs are not
  recoverable from the Claude transcript.
- Genuinely unknown record types (a future Codex schema addition not in
  the documented drop-list) emit a stderr warning and are dropped. This
  surfaces silent loss instead of letting it accumulate.
- Source `cwd` is read from the most recent record that carries one;
  runtime cwd at resume time overrides per receiver behavior.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time
import uuid
from collections import Counter
from pathlib import Path
from typing import Any


def _install_sigterm_handler() -> None:
    """Promote SIGTERM to SystemExit so write_jsonl's BaseException cleanup
    block runs and the .tmp file is unlinked. Default SIGTERM behavior on
    POSIX terminates the process without raising, leaving stale tmp files.

    Called from main() only. Library callers (anyone importing this module
    and calling claude_to_codex/codex_to_claude directly) must install
    their own SIGTERM handler if they want the .tmp cleanup contract — we
    do not auto-install at module load because that would silently
    overwrite any signal handler the embedding application has set up."""
    def _raise_systemexit(_signum: int, _frame: Any) -> None:
        raise SystemExit(143)
    try:
        signal.signal(signal.SIGTERM, _raise_systemexit)
    except (ValueError, OSError):
        # Non-main thread or platform without signal support; best-effort.
        pass


def _codex_session_bases() -> list[Path]:
    primary = os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")
    second = os.environ.get("SECOND_CODEX_HOME") or str(Path.home() / ".codex-second")
    return [Path(primary) / "sessions", Path(second) / "sessions"]


def _claude_projects_base() -> Path:
    home = os.environ.get("CLAUDE_HOME") or str(Path.home() / ".claude")
    return Path(home) / "projects"


# Tool name mapping. Only tools with a clean structural equivalent on the
# other side are listed here. Unmapped tools are folded into descriptive
# text blocks (so the receiving model still sees the prior tool history but
# in a form that does not depend on the receiver recognizing the tool's
# schema). Adding an entry requires the tool to exist on both sides AND for
# the argument shapes to be losslessly translatable via the corresponding
# _normalize_tool_input helper.
CLAUDE_TO_CODEX_TOOL = {
    "Bash": "exec_command",
}
CODEX_TO_CLAUDE_TOOL = {
    "exec_command": "Bash",
    "shell": "Bash",
}


# Documented dispatch contracts. Anything not in HANDLED ∪ DOCUMENTED_DROP
# is treated as a future-schema unknown and triggers a stderr warning so
# silent data loss does not accumulate as Codex/Claude evolve. Update these
# sets together with the docstring above when adding handlers or when a new
# record type's drop is intentional.
_CODEX_RESPONSE_ITEM_HANDLED: frozenset[str] = frozenset({
    "message", "function_call", "function_call_output",
    "custom_tool_call", "custom_tool_call_output",
    "web_search_call", "tool_search_call", "tool_search_output",
})
_CODEX_RESPONSE_ITEM_DOCUMENTED_DROP: frozenset[str] = frozenset({
    "reasoning",
})
_CODEX_RESPONSE_MESSAGE_ROLE_DOCUMENTED_DROP: frozenset[str] = frozenset({
    # Codex uses response_item.message(role=developer) for runtime policy and
    # environment context (permissions, sandbox, AGENTS.md injection). Replaying
    # it as Claude user text would import stale source-process constraints into
    # a different runtime, so this role is a documented cross-vendor boundary.
    "developer",
})
_CODEX_EVENT_MSG_HANDLED: frozenset[str] = frozenset({
    "user_message", "task_started", "task_complete", "turn_aborted",
})
# `agent_message` is empirically a duplicate of the same-turn
# response_item.message in ~88% of normal sessions (see module docstring),
# so dropping it avoids duplicating assistant content. The empirical
# corpus did not include subagent rollouts (the `collab_*` event types
# below hint that Codex has a sub-agent feature); if a future maintainer
# adds a handler thinking content is being lost, see scenario W and the
# docstring's "intentional drop" note before changing behavior.
_CODEX_EVENT_MSG_DOCUMENTED_DROP: frozenset[str] = frozenset({
    "agent_message", "agent_reasoning",
    "token_count", "exec_command_end", "patch_apply_end",
    "mcp_tool_call_end", "guardian_assessment",
    "collab_waiting_end", "collab_agent_spawn_end",
    "collab_close_end", "collab_agent_interaction_end",
    "web_search_end", "context_compacted", "thread_name_updated",
    "error", "dynamic_tool_call_request",
    # Empirically observed in real local rollouts (2026-05-04 corpus scan):
    # dynamic_tool_call_response is content-bearing but its payload is also
    # carried by the matching response_item.function_call_output (same
    # call_id), so dropping the event_msg avoids duplicating tool output.
    # thread_rolled_back is pure metadata ({"num_turns": N}). item_completed
    # is a turn-completion marker.
    "dynamic_tool_call_response", "thread_rolled_back", "item_completed",
})
_CLAUDE_RECORD_HANDLED: frozenset[str] = frozenset({
    "user", "assistant",
})
_CLAUDE_RECORD_DOCUMENTED_DROP: frozenset[str] = frozenset({
    "attachment", "file-history-snapshot", "system", "progress",
    "last-prompt", "permission-mode", "queue-operation", "pr-link",
    "summary", "custom-title", "agent-name",
})

# Codex turn_context.approval_policy enum. Empirical scan of 4870 local
# rollouts shows real-world values are "on-request" and "never"; the full
# enum from Codex's source includes "untrusted" and "on-failure" which we
# accept as well so users can opt into stricter Codex behavior on resume.
_VALID_CODEX_APPROVAL_POLICIES: frozenset[str] = frozenset({
    "untrusted", "on-request", "on-failure", "never",
})
# Codex turn_context.sandbox_policy.type enum (Codex uses `type` as the
# tagged-union discriminator, NOT `mode`). Empirical scan of 4869 native
# local Codex rollouts: every record uses `type`. The pre-#6 converter
# wrote `mode`, an unrecognized field that does not match Codex's tagged-
# union schema; whether `codex resume` silently drops the field, falls
# back to a default policy, or refuses the rollout was not directly
# measured (live-resume verification of the legacy emission was not run).
# The schema fix is safe-by-construction: writing what 4869/4869 native
# rollouts write removes an entire class of "unrecognized field" risk.
# "workspace-write" is the most common value, with "danger-full-access"
# and "read-only" also observed. Conservative default is "read-only" so
# a converted session never silently escalates filesystem access on
# resume.
_VALID_CODEX_SANDBOX_TYPES: frozenset[str] = frozenset({
    "read-only", "workspace-write", "danger-full-access",
})
_DEFAULT_CODEX_APPROVAL_POLICY: str = "on-request"
_DEFAULT_CODEX_SANDBOX_TYPE: str = "read-only"


def _build_codex_sandbox_policy(sandbox_type: str, _cwd: str) -> dict[str, Any]:
    """Build the sandbox_policy dict Codex's resume parser expects.

    Codex represents sandbox_policy as a tagged union keyed on `type`. For
    `read-only` and `danger-full-access` the only field is `type`. For
    `workspace-write` Codex also stores `writable_roots`, `network_access`,
    `exclude_tmpdir_env_var`, `exclude_slash_tmp`.

    `writable_roots` lists the *additional* paths beyond cwd that
    `workspace-write` makes writable (cwd is implicitly writable by the
    workspace-write semantic itself). Empirical scan of 1801 native local
    workspace-write rollouts: 1757 (97.5%) carry exactly
    `["~/.codex/memories"]`; 25 (1.4%) add per-tool config dirs alongside;
    19 (1%) carry only cwd. We default to the dominant memories-only
    pattern so converted sessions look indistinguishable from native
    Codex's typical workspace-write rollout. Users who need additional
    writable paths can edit the produced rollout (or wait on a future
    iteration that exposes per-field flags).

    `network_access`, `exclude_tmpdir_env_var`, `exclude_slash_tmp`
    default to `false` (most conservative — no network, no tmp
    exclusions). `_cwd` (underscore-prefixed) is intentionally unused in
    the default — workspace-write makes cwd implicitly writable, so
    redundant entries in writable_roots are unnecessary. Kept in the
    signature for callers that may opt into a non-default writable root
    set (e.g., `[cwd, ~/.codex/memories]`) in a future iteration.
    """
    if sandbox_type == "workspace-write":
        return {
            "type": "workspace-write",
            "writable_roots": [os.path.expanduser("~/.codex/memories")],
            "network_access": False,
            "exclude_tmpdir_env_var": False,
            "exclude_slash_tmp": False,
        }
    return {"type": sandbox_type}


def _warn_unknown(category: str, kind: str, seen: set[str]) -> None:
    """Emit a single stderr warning per unknown (category, kind) pair.

    Deduped because real sessions can carry hundreds of the same unknown
    type and a per-record warning would flood stderr. Once-per-kind is
    enough to surface the schema gap.
    """
    key = f"{category}:{kind}"
    if key in seen:
        return
    seen.add(key)
    sys.stderr.write(
        f"session_convert: warning: unhandled {category} type {kind!r} "
        f"(future Codex/Claude schema?). Records of this type are dropped; "
        f"add a handler or extend DOCUMENTED_DROP if drop is intentional.\n"
    )


def gen_uuid_v7() -> str:
    """Return a UUIDv7-shaped string. Falls back to time-prefixed v4 on Python <3.13."""
    fn = getattr(uuid, "uuid7", None)
    if fn is not None:
        return str(fn())
    ts_ms = int(time.time() * 1000)
    ts_hex = f"{ts_ms:012x}"
    rand = secrets.token_hex(10)
    # RFC 9562 §5.7: variant nibble (group 4 char 0) must encode 10xx_2 → {8,9,a,b}.
    variant = f"{(int(rand[3], 16) & 0x3) | 0x8:x}"
    return f"{ts_hex[:8]}-{ts_hex[8:12]}-7{rand[0:3]}-{variant}{rand[4:7]}-{rand[7:19]}"


def gen_claude_tool_id() -> str:
    return f"toolu_{secrets.token_urlsafe(16).replace('-', 'A').replace('_', 'B')}"[:30]


def gen_codex_call_id() -> str:
    return f"call_{secrets.token_urlsafe(20).replace('-', 'A').replace('_', 'B')}"[:30]


_CLAUDE_PROJECT_BAD_CHAR = re.compile(r"[^A-Za-z0-9-]")


def encode_claude_project(cwd: str) -> str:
    """Match Claude Code's project directory encoding.

    Reverse-engineered from 64 real sessions in ~/.claude/projects on
    macOS (2026-05-04 local data). Empirical fit was 63/64 with the rule
    "realpath, then replace every non-[A-Za-z0-9-] character with `-`".
    The remaining 1 was a session our converter wrote with the old buggy
    rule.

    Why realpath: macOS symlinks /tmp → /private/tmp and /var → /private/var,
    so a converter writing under /tmp would emit -tmp-foo while
    `claude --resume` (run from the same /tmp dir) resolves to
    /private/tmp/foo and looks under -private-tmp-foo. Without realpath
    the file is invisible to resume.

    Why the broader char strip: Claude replaces dots, underscores, and
    spaces with dashes too — `/Users/me/.claude` becomes
    -Users-me--claude, `clone_dir` becomes clone-dir, and
    `Application Support` becomes Application-Support.
    """
    real = os.path.realpath(cwd) if cwd.startswith("/") else cwd
    return _CLAUDE_PROJECT_BAD_CHAR.sub("-", real)


_FULL_UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)


def _validate_session_uuid(value: str, label: str) -> None:
    """Reject empty / sub-string UUIDs upfront. The bash wrapper enforces the
    same regex; this Python-side check makes the contract consistent for
    direct CLI use."""
    if not _FULL_UUID_RE.match(value or ""):
        raise ValueError(f"{label} session id must be a full UUID, got {value!r}")


def find_codex_session(uuid_value: str) -> Path:
    _validate_session_uuid(uuid_value, "Codex")
    bases = _codex_session_bases()
    matches = []
    for base in bases:
        if not base.exists():
            continue
        for path in base.rglob("rollout-*.jsonl"):
            if uuid_value in path.name:
                matches.append(path)
    if not matches:
        raise FileNotFoundError(f"No Codex rollout matching '{uuid_value}' under {bases}")
    if len(matches) > 1:
        raise ValueError(f"Ambiguous Codex UUID '{uuid_value}': matches {len(matches)} files")
    return matches[0]


def find_claude_session(uuid_value: str) -> Path:
    _validate_session_uuid(uuid_value, "Claude")
    base = _claude_projects_base()
    if not base.exists():
        raise FileNotFoundError(f"Claude projects directory missing: {base}")
    matches = []
    for project in base.iterdir():
        if not project.is_dir():
            continue
        for path in project.glob("*.jsonl"):
            if uuid_value in path.name:
                matches.append(path)
    if not matches:
        raise FileNotFoundError(f"No Claude session matching '{uuid_value}' under {base}")
    if len(matches) > 1:
        raise ValueError(f"Ambiguous Claude UUID '{uuid_value}': matches {len(matches)} files")
    return matches[0]


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    out = []
    # encoding="utf-8" is explicit so behavior does not depend on
    # locale.getpreferredencoding(); under PYTHONUTF8=0 LC_ALL=C the default
    # is ASCII. errors="replace" keeps a stray non-UTF-8 byte from raising
    # UnicodeDecodeError mid-stream — invalid bytes become �, the line
    # then either parses (rare) or fails json.loads with a clear warning.
    with path.open(encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as exc:
                # Log to stderr so bugs in the source file are surfaced rather
                # than silently dropping data. Conversion still proceeds.
                # Avoid echoing exc message content (may quote source bytes);
                # exception class + byte position is enough for diagnosis.
                sys.stderr.write(
                    f"session_convert: warning: skipping malformed JSON line "
                    f"{lineno} (col {exc.colno}) in {path}: {type(exc).__name__}\n"
                )
                continue
    return out


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    """Write atomically: stream into <path>.tmp, then rename. Prevents a
    partial write from leaving the canonical session path corrupt if the
    process is interrupted mid-stream."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        # Pin encoding so writing emoji/CJK content does not depend on the
        # host locale (mirror of read_jsonl's open).
        with tmp.open("w", encoding="utf-8") as f:
            for r in records:
                # ensure_ascii=False keeps unicode content readable and matches
                # how native sessions are stored on disk.
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        os.replace(tmp, path)
    except BaseException:
        # Clean up the temp file on any failure (including KeyboardInterrupt).
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())


_TS_FRACTION_RE = re.compile(r"^(.*\d{2}:\d{2}:\d{2})\.(\d{1,9})Z$")
_TS_NO_FRACTION_RE = re.compile(r"^(.*\d{2}:\d{2}:\d{2})Z$")


def _bump_ts_ms(ts: str, n: int) -> str:
    """Return ts shifted forward by n milliseconds, preserving '...Z' shape.

    Used so multiple converted records derived from a single source record
    carry distinct timestamps in source order, instead of all sharing the
    same string. Defensive on malformed input — returns ts unchanged when
    the expected '...HH:MM:SS.fracZ' or '...HH:MM:SSZ' shape is not present.

    Fraction precision: ISO-8601 lets the fractional part be any number
    of digits. We normalize to milliseconds (3 digits): a 1-2 digit
    fraction like '.12' (which means 120ms, not 12ms) is left-padded
    to '.120' before adding n; a longer fraction like microseconds
    '.123456' is truncated to '.123' before bumping. Multi-dot
    pathological inputs (e.g. '...00.123.456Z') don't match the regex
    and are returned unchanged.
    """
    if n <= 0 or not ts.endswith("Z"):
        return ts
    m = _TS_FRACTION_RE.match(ts)
    if m:
        head, frac = m.group(1), m.group(2)
        # Normalize fraction to milliseconds: pad short, truncate long.
        if len(frac) < 3:
            frac = frac.ljust(3, "0")
        else:
            frac = frac[:3]
        try:
            ms = int(frac)
        except ValueError:
            return ts
        new_ms = ms + n
        if new_ms >= 1000:
            # Cap at .999 rather than rolling into seconds; > 999
            # emissions per source record is unrealistic for any session.
            new_ms = 999
        return f"{head}.{new_ms:03d}Z"
    m = _TS_NO_FRACTION_RE.match(ts)
    if m:
        new_ms = min(n, 999)
        return f"{m.group(1)}.{new_ms:03d}Z"
    return ts


def codex_rollout_path(new_uuid: str) -> Path:
    """Build the canonical Codex rollout path for a new UUID under today's date dir."""
    now = time.gmtime()
    primary = _codex_session_bases()[0]
    date_dir = primary / time.strftime("%Y/%m/%d", now)
    ts = time.strftime("%Y-%m-%dT%H-%M-%S", now)
    return date_dir / f"rollout-{ts}-{new_uuid}.jsonl"


def claude_session_path(new_uuid: str, cwd: str) -> Path:
    return _claude_projects_base() / encode_claude_project(cwd) / f"{new_uuid}.jsonl"


# ---------------------------------------------------------------------------
# Codex -> Claude
# ---------------------------------------------------------------------------


def _records_after_aborts_filtered(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Drop response_items emitted between the most recent task_started and a
    matching turn_aborted. The source model treated those records as
    abandoned; including them in the converted output would feed the receiver
    content the original model never committed.

    Implementation: walk records once, mark any response_item record that
    falls between a task_started and a subsequent turn_aborted (without an
    intervening task_complete) for removal.
    """
    keep = [True] * len(records)
    # Stack of unmatched task_started indices. Real Codex rollouts emit
    # un-paired task_started runs in subagent / nested-task contexts (24
    # of 468 local rollouts, 2026-05-04 corpus scan, exhibit a `task_started
    # … task_started` sequence with no intervening lifecycle event). A
    # scalar would silently overwrite the outer index, so a later
    # turn_aborted at the outer level would do nothing and leak abandoned
    # content. The stack rolls back to the innermost open task per abort.
    pending_starts: list[int] = []
    for i, r in enumerate(records):
        rtype = r.get("type")
        ptype: str | None = None
        if rtype == "event_msg":
            payload = r.get("payload", {}) if isinstance(r.get("payload"), dict) else {}
            ptype = payload.get("type")
        # Real Codex rollouts emit task_started / task_complete / turn_aborted
        # nested inside event_msg.payload.type (verified by corpus scan at
        # development time — every observed instance was nested, none top-
        # level). The top-level alternatives are kept defensively in case an
        # older or future Codex version emits the simpler shape.
        if rtype == "task_started" or ptype == "task_started":
            pending_starts.append(i)
        elif rtype == "task_complete" or ptype == "task_complete":
            if pending_starts:
                pending_starts.pop()
        elif rtype == "turn_aborted" or ptype == "turn_aborted":
            if pending_starts:
                start = pending_starts.pop()
                for j in range(start + 1, i):
                    if records[j].get("type") == "response_item":
                        keep[j] = False
    return [r for r, k in zip(records, keep) if k]


def codex_to_claude(src: Path, target_cwd: str | None = None) -> tuple[Path, str]:
    """Convert a Codex rollout to a Claude session. Returns (output path, new uuid)."""
    # Reject empty / whitespace-only target_cwd at the Python boundary too.
    # The bash wrapper already rejects an empty --target-cwd, but a direct
    # library / `python3 lib/session_convert.py … --target-cwd ""` (or
    # `"   "`) call would otherwise fall through `or` to source/runtime
    # cwd, silently ignoring the explicit user intent.
    if target_cwd is not None and not target_cwd.strip():
        raise ValueError("--target-cwd must not be empty or whitespace-only")
    records = read_jsonl(src)
    records = _records_after_aborts_filtered(records)
    session_meta = next((r for r in records if r.get("type") == "session_meta"), None)
    if session_meta is None:
        raise ValueError(f"Source has no session_meta record: {src}")

    # Pick cwd: explicit override beats most-recent record-level cwd, which
    # beats session_meta.cwd, which beats the runtime cwd as a last resort.
    src_cwd_recent: str | None = None
    for r in records:
        c = r.get("payload", {}).get("cwd") if isinstance(r.get("payload"), dict) else None
        if c:
            src_cwd_recent = c
    cwd_raw = (
        target_cwd
        or src_cwd_recent
        or session_meta.get("payload", {}).get("cwd")
        or os.getcwd()
    )
    # realpath() not abspath(): empirical Class F probe (2026-05-04) showed
    # `claude --resume` resolves the cwd via realpath before encoding, so
    # writing under /tmp produces -tmp-foo but Claude scans -private-tmp-foo
    # on macOS. Use realpath so the converter writes where Claude looks.
    # realpath also collapses `..` (subsumes abspath's behavior).
    cwd = os.path.realpath(os.path.expanduser(cwd_raw))
    new_uuid = gen_uuid_v7()

    out: list[dict[str, Any]] = []
    parent_uuid: str | None = None
    call_id_to_tool_id: dict[str, str] = {}
    unknown_call_ids: set[str] = set()
    custom_tool_call_ids: set[str] = set()
    warned_unknowns: set[str] = set()
    def codex_message_blocks(payload_obj: dict[str, Any], string_block_type: str) -> list[Any]:
        content = payload_obj.get("content", [])
        if isinstance(content, str):
            return [{"type": string_block_type, "text": content}]
        if isinstance(content, list):
            return content
        # Malformed/future content containers have no portable text blocks.
        # Drop them at the role handler rather than stringifying structured
        # runtime data into the receiver transcript.
        return []

    def codex_user_text_echo(payload_obj: dict[str, Any]) -> str:
        parts = []
        for block_obj in codex_message_blocks(payload_obj, "input_text"):
            if isinstance(block_obj, dict) and block_obj.get("type") == "input_text":
                text = block_obj.get("text") or ""
                if text:
                    parts.append(text)
        return "".join(parts)

    response_item_user_echoes = Counter(
        text for rec in records
        if rec.get("type") == "response_item"
        and isinstance(rec.get("payload"), dict)
        and rec["payload"].get("type") == "message"
        and rec["payload"].get("role") == "user"
        for text in [codex_user_text_echo(rec["payload"])]
        if text
    )
    # Tracks the source record's timestamp for the current loop iteration so
    # converted records inherit it (preserving session ordering across the
    # handoff). Falls back to now_iso() when the source record has none.
    current_source_ts: str | None = None

    def make_record(rtype: str, message: dict[str, Any], extras: dict[str, Any] | None = None) -> dict[str, Any]:
        nonlocal parent_uuid
        rec_uuid = str(uuid.uuid4())
        rec: dict[str, Any] = {
            "type": rtype,
            "uuid": rec_uuid,
            "parentUuid": parent_uuid,
            "sessionId": new_uuid,
            "cwd": cwd,
            "version": "1.0.0",
            "userType": "external",
            "timestamp": current_source_ts or now_iso(),
            "isSidechain": False,
            "message": message,
        }
        if extras:
            rec.update(extras)
        parent_uuid = rec_uuid
        return rec

    for r in records:
        ts_field = r.get("timestamp")
        current_source_ts = ts_field if isinstance(ts_field, str) else None
        rtype = r.get("type")
        payload = r.get("payload", {}) if isinstance(r.get("payload"), dict) else {}
        if rtype == "event_msg":
            ev_ptype = payload.get("type")
            if ev_ptype == "user_message":
                text = payload.get("message", "")
                if not text:
                    continue
                if response_item_user_echoes[text] > 0:
                    response_item_user_echoes[text] -= 1
                    continue
                out.append(make_record(
                    "user",
                    {"role": "user", "content": [{"type": "text", "text": text}]},
                ))
                continue
            # task_started / task_complete / turn_aborted are handled upstream
            # by _records_after_aborts_filtered; they're no-ops here.
            if ev_ptype in _CODEX_EVENT_MSG_HANDLED or ev_ptype in _CODEX_EVENT_MSG_DOCUMENTED_DROP:
                continue
            if isinstance(ev_ptype, str):
                _warn_unknown("event_msg.payload", ev_ptype, warned_unknowns)
            continue

        if rtype != "response_item":
            # session_meta / turn_context / compacted are documented drops on
            # codex→claude. Top-level task_started/task_complete/turn_aborted
            # are handled by the abort filter before this loop. Anything else
            # is an unknown future top-level type; surface it.
            if isinstance(rtype, str) and rtype not in {
                "session_meta", "turn_context", "compacted",
                "task_started", "task_complete", "turn_aborted",
            }:
                _warn_unknown("top-level", rtype, warned_unknowns)
            continue

        ptype = payload.get("type")
        if ptype == "message" and payload.get("role") == "assistant":
            content_blocks = []
            for block in codex_message_blocks(payload, "output_text"):
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                text = block.get("text") or ""
                # Historical Codex message payloads have appeared with
                # input_text under assistant roles; keep accepting it as
                # compatibility text while user-role messages own input_text
                # in the normal schema.
                if btype in ("output_text", "input_text") and text:
                    content_blocks.append({"type": "text", "text": text})
            if not content_blocks:
                continue
            out.append(make_record(
                "assistant",
                {
                    "id": f"msg_xfmt_{secrets.token_hex(8)}",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-opus-4-7",
                    "content": content_blocks,
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
                extras={"requestId": f"req_xfmt_{secrets.token_hex(8)}"},
            ))
        elif ptype == "message" and payload.get("role") == "user":
            content_blocks = []
            for block in codex_message_blocks(payload, "input_text"):
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                text = block.get("text") or ""
                if btype == "input_text" and text:
                    content_blocks.append({"type": "text", "text": text})
                elif btype == "input_image":
                    content_blocks.append({
                        "type": "text",
                        "text": "[Codex user image attachment omitted during cross-vendor handoff]",
                    })
            if not content_blocks:
                continue
            out.append(make_record(
                "user",
                {"role": "user", "content": content_blocks},
            ))
        elif (
            ptype == "message"
            and isinstance(payload.get("role"), str)
            and payload.get("role") in _CODEX_RESPONSE_MESSAGE_ROLE_DOCUMENTED_DROP
        ):
            continue
        elif ptype == "message":
            role = payload.get("role")
            if isinstance(role, str):
                _warn_unknown("response_item.message.role", role, warned_unknowns)
            elif role is None:
                _warn_unknown("response_item.message.role", "<missing>", warned_unknowns)
            else:
                # Surface malformed/future role shapes without echoing their
                # value, since role-bearing records can contain runtime
                # context that should not leak to stderr.
                _warn_unknown(
                    "response_item.message.role",
                    f"<non-string:{type(role).__name__}>",
                    warned_unknowns,
                )
        elif ptype == "function_call":
            call_id = payload.get("call_id", "")
            tool_name_codex = payload.get("name", "")
            args_str = payload.get("arguments", "{}")
            try:
                args = json.loads(args_str) if isinstance(args_str, str) else args_str
            except json.JSONDecodeError:
                args = {"raw_arguments": args_str}
            if tool_name_codex in CODEX_TO_CLAUDE_TOOL:
                tool_name_claude = CODEX_TO_CLAUDE_TOOL[tool_name_codex]
                tool_use_id = gen_claude_tool_id()
                call_id_to_tool_id[call_id] = tool_use_id
                out.append(make_record(
                    "assistant",
                    {
                        "id": f"msg_xfmt_{secrets.token_hex(8)}",
                        "type": "message",
                        "role": "assistant",
                        "model": "claude-opus-4-7",
                        "content": [
                            {"type": "tool_use", "id": tool_use_id, "name": tool_name_claude,
                             "input": _normalize_tool_input(tool_name_claude, args)},
                        ],
                        "stop_reason": "tool_use",
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    },
                    extras={"requestId": f"req_xfmt_{secrets.token_hex(8)}"},
                ))
            else:
                # Fold unmapped tool call into descriptive text. The receiving
                # Claude API may reject unknown tool names; rendering as text
                # preserves the narrative without depending on tool schema.
                # Skip empty call_id when tracking (parallel guard to
                # custom_tool_call_ids — empty isn't a real linkage key).
                if call_id:
                    unknown_call_ids.add(call_id)
                preview = json.dumps(args) if isinstance(args, (dict, list)) else str(args)
                out.append(make_record(
                    "assistant",
                    {
                        "id": f"msg_xfmt_{secrets.token_hex(8)}",
                        "type": "message",
                        "role": "assistant",
                        "model": "claude-opus-4-7",
                        "content": [{"type": "text",
                                     "text": f"[Used Codex tool `{tool_name_codex}` with arguments: {preview}]"}],
                        "stop_reason": "end_turn",
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    },
                    extras={"requestId": f"req_xfmt_{secrets.token_hex(8)}"},
                ))
        elif ptype == "function_call_output":
            call_id = payload.get("call_id", "")
            output = payload.get("output", "")
            if call_id and call_id in unknown_call_ids:
                # Companion fold for an unmapped tool call.
                out.append(make_record(
                    "user",
                    {"role": "user", "content": [{"type": "text",
                                                  "text": f"[Tool result: {output}]"}]},
                ))
                continue
            tool_use_id = call_id_to_tool_id.get(call_id)
            if tool_use_id is None:
                # Orphan output (no matching call). Wrap in `[Orphan tool result: ...]`
                # to mark broken linkage explicitly, parity with the orphan
                # branches in `custom_tool_call_output` and the README's
                # documented contract for orphan handling.
                if not output:
                    continue
                out.append(make_record(
                    "user",
                    {"role": "user", "content": [
                        {"type": "text", "text": f"[Orphan tool result: {output}]"}
                    ]},
                ))
                continue
            out.append(make_record(
                "user",
                {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": tool_use_id, "content": str(output), "is_error": False},
                ]},
            ))
        elif ptype == "custom_tool_call":
            # Codex custom tools (e.g. apply_patch) carry a free-form `input`
            # string instead of the function_call `arguments` JSON. Claude has
            # no equivalent first-class tool, so fold to descriptive text —
            # same shape as the unmapped function_call branch above.
            call_id = payload.get("call_id", "")
            tool_name = payload.get("name", "") or "custom_tool"
            tool_input = payload.get("input", "")
            preview = tool_input if isinstance(tool_input, str) else json.dumps(tool_input)
            # Skip empty call_id when tracking — empty isn't a real linkage
            # key. Without this guard, an empty-id call followed by an
            # empty-id output would falsely match as a companion pair even
            # though the IDs are meaningless. Real Codex always emits a
            # proper `call_*` id; this guard handles malformed sources.
            if call_id:
                custom_tool_call_ids.add(call_id)
            out.append(make_record(
                "assistant",
                {
                    "id": f"msg_xfmt_{secrets.token_hex(8)}",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-opus-4-7",
                    "content": [{"type": "text",
                                 "text": f"[Used Codex tool `{tool_name}` with input: {preview}]"}],
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
                extras={"requestId": f"req_xfmt_{secrets.token_hex(8)}"},
            ))
        elif ptype == "custom_tool_call_output":
            call_id = payload.get("call_id", "")
            output = payload.get("output", "")
            # Companion fold for a custom_tool_call. If the matching call
            # record was filtered upstream (e.g. abandoned in a turn_aborted)
            # OR call_id is empty (no real linkage), surface as orphan so a
            # reader of the converted session can tell the linkage is broken.
            prefix = "Tool result" if call_id and call_id in custom_tool_call_ids else "Orphan tool result"
            out.append(make_record(
                "user",
                {"role": "user", "content": [{"type": "text",
                                              "text": f"[{prefix}: {output}]"}]},
            ))
        elif ptype in ("web_search_call", "tool_search_call"):
            # No call_id / output linkage in the schema — render the action
            # (search query or open_page url) so the model still sees the
            # search intent in the converted history.
            action = payload.get("action") or {}
            atype = action.get("type") if isinstance(action, dict) else ""
            if atype == "search":
                query = action.get("query") or ""
                queries = action.get("queries") or []
                detail = query or " | ".join(str(q) for q in queries)
                summary = f"search: {detail}" if detail else "search"
            elif atype == "open_page":
                summary = f"open_page: {action.get('url', '')}"
            else:
                summary = json.dumps(action) if isinstance(action, (dict, list)) else "(no action)"
            out.append(make_record(
                "assistant",
                {
                    "id": f"msg_xfmt_{secrets.token_hex(8)}",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-opus-4-7",
                    "content": [{"type": "text",
                                 "text": f"[Used Codex tool `{ptype}` with action: {summary}]"}],
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
                extras={"requestId": f"req_xfmt_{secrets.token_hex(8)}"},
            ))
        elif ptype == "tool_search_output":
            output = payload.get("output", "")
            out.append(make_record(
                "user",
                {"role": "user", "content": [{"type": "text",
                                              "text": f"[Tool result: {output}]"}]},
            ))
        elif ptype in _CODEX_RESPONSE_ITEM_DOCUMENTED_DROP:
            # reasoning: cross-vendor unforgeable signature; drop is intentional.
            continue
        elif isinstance(ptype, str):
            # Unknown future response_item type. Surface so silent loss does
            # not accumulate as the schema evolves.
            _warn_unknown("response_item.payload", ptype, warned_unknowns)

    target_path = claude_session_path(new_uuid, cwd)
    write_jsonl(target_path, out)
    return target_path, new_uuid


def _normalize_tool_input(tool_name: str, args: Any) -> dict[str, Any]:
    """Map tool-specific argument shapes between Codex and Claude conventions."""
    if not isinstance(args, dict):
        return {"raw_arguments": str(args)}
    if tool_name == "Bash":
        # Codex exec_command uses {cmd, workdir, ...}. Claude Bash uses {command, description}.
        cmd = args.get("cmd") or args.get("command") or ""
        return {"command": cmd, "description": args.get("description") or "Translated from Codex"}
    return args


# ---------------------------------------------------------------------------
# Claude -> Codex
# ---------------------------------------------------------------------------


def _detect_codex_cli_version() -> str:
    """Best-effort plumbing of the local Codex CLI version into session_meta.
    Falls back to a sentinel rather than failing the conversion when codex
    is not installed or the output shape changes."""
    try:
        # capture as bytes + manual decode with errors="replace" so this is
        # immune to LC_ALL=C (text=True would raise UnicodeDecodeError if the
        # codex binary ever emits a non-ASCII byte under an ASCII locale).
        res = subprocess.run(
            ["codex", "--version"], capture_output=True, timeout=2
        )
        if res.returncode == 0:
            stdout = res.stdout.decode("utf-8", errors="replace") if res.stdout else ""
            # Output is like "OpenAI Codex v0.128.0 (research preview)" or
            # similar. Extract the first vN.N.N-shaped token if present.
            m = re.search(r"v?(\d+\.\d+\.\d+)", stdout)
            if m:
                return m.group(1)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        pass
    return "0.0.0-translated"


def claude_to_codex(
    src: Path,
    target_cwd: str | None = None,
    codex_approval_policy: str = _DEFAULT_CODEX_APPROVAL_POLICY,
    codex_sandbox_policy: str = _DEFAULT_CODEX_SANDBOX_TYPE,
) -> tuple[Path, str]:
    """Convert a Claude session to a Codex rollout. Returns (output path, new uuid).

    `codex_approval_policy` and `codex_sandbox_policy` populate the
    converted session's `turn_context` so `codex resume` honors the
    intended permission posture instead of silently auto-approving every
    command (the pre-#6 default of `"never"` + a wrong-schema sandbox
    policy effectively dropped any safety gate). Both axes default to the
    conservative end of Codex's enum (`on-request` + `read-only`); users
    who need looser semantics opt in explicitly.
    """
    if target_cwd is not None and not target_cwd.strip():
        raise ValueError("--target-cwd must not be empty or whitespace-only")
    if codex_approval_policy not in _VALID_CODEX_APPROVAL_POLICIES:
        raise ValueError(
            f"codex_approval_policy (CLI: --codex-approval-policy) must be "
            f"one of {sorted(_VALID_CODEX_APPROVAL_POLICIES)}; "
            f"got {codex_approval_policy!r}"
        )
    if codex_sandbox_policy not in _VALID_CODEX_SANDBOX_TYPES:
        raise ValueError(
            f"codex_sandbox_policy (CLI: --codex-sandbox-policy) must be "
            f"one of {sorted(_VALID_CODEX_SANDBOX_TYPES)}; "
            f"got {codex_sandbox_policy!r}"
        )
    records = read_jsonl(src)
    if not records:
        raise ValueError(f"Source is empty: {src}")

    # Pick cwd: explicit override beats most-recent record-level cwd, which
    # beats the runtime cwd as a last resort. Most-recent over first-found
    # because users sometimes change directories mid-session.
    src_cwd: str | None = None
    for r in records:
        c = r.get("cwd")
        if c:
            src_cwd = c
    cwd_raw = target_cwd or src_cwd or os.getcwd()
    # realpath (mirror of codex_to_claude). Native Codex captures cwd via
    # POSIX getcwd() which returns the physical path on macOS, so a rollout
    # generated by codex itself stores /private/tmp/foo (not /tmp/foo).
    # Match that convention so the converted rollout looks indistinguishable
    # to `codex resume` from a native one.
    cwd = os.path.realpath(os.path.expanduser(cwd_raw))
    new_uuid = gen_uuid_v7()
    cli_version = _detect_codex_cli_version()

    out: list[dict[str, Any]] = []
    tool_id_to_call_id: dict[str, str] = {}
    warned_unknowns: set[str] = set()

    out.append({
        "timestamp": now_iso(),
        "type": "session_meta",
        "payload": {
            "id": new_uuid,
            "timestamp": now_iso(),
            "cwd": cwd,
            # `originator` is intentionally distinct from native codex-tui /
            # codex-exec values so converted rollouts are recognizable for
            # debugging.
            "originator": "second-codex-handoff",
            "cli_version": cli_version,
            "source": "cli",
            "model_provider": "openai",
            "base_instructions": {"text": "You are Codex, a coding agent.\n"},
        },
    })
    out.append({
        "timestamp": now_iso(),
        "type": "turn_context",
        "payload": {
            "cwd": cwd,
            "approval_policy": codex_approval_policy,
            "sandbox_policy": _build_codex_sandbox_policy(codex_sandbox_policy, cwd),
            "model": "gpt-5.5",
            "effort": "none",
            "summary": "none",
        },
    })

    for r in records:
        # Preserve the source record's timestamp so converted records inherit
        # the original ordering. Falls back to now_iso() when missing.
        ts_field = r.get("timestamp")
        src_ts_raw = ts_field if isinstance(ts_field, str) else now_iso()
        # Multiple output records can be derived from a single source record
        # (e.g. an assistant turn with text + tool_use). emit_n bumps the
        # timestamp by 1ms per emission so the converted records remain
        # distinguishable in source order, matching real Codex rollouts that
        # give every record a distinct time.
        emit_n = 0
        rtype = r.get("type")
        # Surface unknown Claude record types so silent loss doesn't grow as
        # the Claude session schema evolves. Documented drops (system,
        # progress, attachment, etc.) stay quiet.
        if isinstance(rtype, str) and rtype not in _CLAUDE_RECORD_HANDLED \
                and rtype not in _CLAUDE_RECORD_DOCUMENTED_DROP:
            _warn_unknown("claude record", rtype, warned_unknowns)
            continue
        message = r.get("message")
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        # Real Claude sessions store user-record content either as a list of
        # blocks (tool_result, text, image, ...) or as a plain string for
        # simple text turns (~17% of real local user records, 2026-05-04
        # corpus scan). Normalize the string form into a single text block
        # so the block loop below handles both shapes — without this,
        # string-content user prompts were silently dropped from converted
        # rollouts.
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if not isinstance(content, list):
            continue

        if rtype == "user" and role == "user":
            # Could be plain text or carry tool_result blocks.
            text_parts = []
            tool_results = []
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text":
                    text_parts.append(block.get("text") or "")
                elif btype == "image":
                    text_parts.append("[Claude user image attachment omitted during cross-vendor handoff]")
                elif btype == "tool_result":
                    tool_results.append(block)
            if text_parts:
                joined = "\n".join(p for p in text_parts if p)
                if joined:
                    out.append({
                        "timestamp": _bump_ts_ms(src_ts_raw, emit_n),
                        "type": "event_msg",
                        "payload": {
                            "type": "user_message",
                            "message": joined,
                            "images": [], "local_images": [], "text_elements": [],
                        },
                    })
                    emit_n += 1
            for tr in tool_results:
                tool_use_id = tr.get("tool_use_id", "")
                output = tr.get("content")
                if isinstance(output, list):
                    output = "\n".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in output)
                output_str = str(output or "")
                if tr.get("is_error"):
                    output_str = f"[error]\n{output_str}"
                call_id = tool_id_to_call_id.get(tool_use_id)
                if call_id == "__unmapped__":
                    # Companion fold for an unmapped tool. Render result as
                    # a user-message text block describing the result.
                    out.append({
                        "timestamp": _bump_ts_ms(src_ts_raw, emit_n),
                        "type": "event_msg",
                        "payload": {
                            "type": "user_message",
                            "message": f"[Tool result: {output_str}]",
                            "images": [], "local_images": [], "text_elements": [],
                        },
                    })
                    emit_n += 1
                    continue
                if call_id is None:
                    # Orphan tool_result (no matching tool_use seen). Fall
                    # back to a fresh call_id so the rollout still validates.
                    call_id = gen_codex_call_id()
                out.append({
                    "timestamp": _bump_ts_ms(src_ts_raw, emit_n),
                    "type": "response_item",
                    "payload": {
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": output_str,
                    },
                })
                emit_n += 1
        elif rtype == "assistant" and role == "assistant":
            text_parts = []
            tool_uses = []
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text":
                    text_parts.append(block.get("text") or "")
                elif btype == "tool_use":
                    tool_uses.append(block)
                # Drop thinking blocks on cross-vendor.
            if text_parts:
                joined = "\n".join(p for p in text_parts if p)
                if joined.strip():
                    out.append({
                        "timestamp": _bump_ts_ms(src_ts_raw, emit_n),
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "role": "assistant",
                            "content": [{"type": "output_text", "text": joined}],
                            "phase": "commentary",
                        },
                    })
                    emit_n += 1
            for tu in tool_uses:
                tool_use_id = tu.get("id", "")
                tool_name_claude = tu.get("name", "")
                input_obj = tu.get("input") or {}
                if tool_name_claude in CLAUDE_TO_CODEX_TOOL:
                    tool_name_codex = CLAUDE_TO_CODEX_TOOL[tool_name_claude]
                    args = _normalize_tool_input_to_codex(tool_name_claude, input_obj, cwd)
                    call_id = gen_codex_call_id()
                    tool_id_to_call_id[tool_use_id] = call_id
                    out.append({
                        "timestamp": _bump_ts_ms(src_ts_raw, emit_n),
                        "type": "response_item",
                        "payload": {
                            "type": "function_call",
                            "name": tool_name_codex,
                            "arguments": json.dumps(args),
                            "call_id": call_id,
                        },
                    })
                    emit_n += 1
                else:
                    # Fold unmapped Claude tool into Codex assistant text. Codex
                    # may not accept arbitrary tool names from a foreign tool
                    # schema, so this stays in the narrative as text.
                    tool_id_to_call_id[tool_use_id] = "__unmapped__"
                    preview = json.dumps(input_obj) if isinstance(input_obj, (dict, list)) else str(input_obj)
                    out.append({
                        "timestamp": _bump_ts_ms(src_ts_raw, emit_n),
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "role": "assistant",
                            "content": [{"type": "output_text",
                                         "text": f"[Used Claude tool `{tool_name_claude}` with input: {preview}]"}],
                            "phase": "commentary",
                        },
                    })
                    emit_n += 1
        # Drop attachment, file-history-snapshot, system, queue-operation, etc.

    target_path = codex_rollout_path(new_uuid)
    write_jsonl(target_path, out)
    return target_path, new_uuid


def _normalize_tool_input_to_codex(tool_name: str, input_obj: dict[str, Any], cwd: str) -> dict[str, Any]:
    if tool_name == "Bash":
        # workdir is lossy on cross-vendor: Claude's Bash tool input has no
        # per-call workdir field, so every converted exec_command call inherits
        # the session-level cwd. If the user `cd`'d mid-session, real per-call
        # workdirs are not recoverable from the Claude transcript.
        return {
            "cmd": input_obj.get("command", ""),
            "workdir": cwd,
            "yield_time_ms": 1000,
            "max_output_tokens": 12000,
        }
    return input_obj


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    _install_sigterm_handler()
    parser = argparse.ArgumentParser(prog="session_convert", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_c2c = sub.add_parser("codex-to-claude", help="Convert a Codex rollout into a Claude session")
    p_c2c.add_argument("uuid", help="Codex session UUID (full or partial)")
    p_c2c.add_argument("--target-cwd", help="Override cwd for the converted session")

    p_cc2 = sub.add_parser("claude-to-codex", help="Convert a Claude session into a Codex rollout")
    p_cc2.add_argument("uuid", help="Claude session UUID (full or partial)")
    p_cc2.add_argument("--target-cwd", help="Override cwd for the converted session")
    p_cc2.add_argument(
        "--codex-approval-policy",
        choices=sorted(_VALID_CODEX_APPROVAL_POLICIES),
        default=_DEFAULT_CODEX_APPROVAL_POLICY,
        help=(
            f"Codex approval_policy emitted into the converted session's "
            f"turn_context (default: {_DEFAULT_CODEX_APPROVAL_POLICY})"
        ),
    )
    p_cc2.add_argument(
        "--codex-sandbox-policy",
        choices=sorted(_VALID_CODEX_SANDBOX_TYPES),
        default=_DEFAULT_CODEX_SANDBOX_TYPE,
        help=(
            f"Codex sandbox_policy.type emitted into the converted "
            f"session's turn_context (default: {_DEFAULT_CODEX_SANDBOX_TYPE})"
        ),
    )

    args = parser.parse_args(argv)

    # Pin stdout/stderr to UTF-8 so emit() can safely print paths containing
    # non-ASCII characters (e.g. user home dirs with CJK / emoji) under
    # PYTHONUTF8=0 LC_ALL=C, where the default stream encoding is ASCII and
    # any non-ASCII byte raises UnicodeEncodeError.
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, AttributeError):
                pass

    def emit(line: str) -> None:
        try:
            sys.stdout.write(line + "\n")
        except UnicodeEncodeError:
            # Defensive: if reconfigure() didn't apply (e.g. wrapped stdout),
            # fall back to a direct UTF-8 byte write.
            sys.stdout.flush()
            sys.stdout.buffer.write((line + "\n").encode("utf-8", errors="replace"))

    if args.cmd == "codex-to-claude":
        src = find_codex_session(args.uuid)
        target, new_uuid = codex_to_claude(src, target_cwd=args.target_cwd)
        emit(f"converted: {src} -> {target}")
        emit(f"new session UUID: {new_uuid}")
        emit(f"resume with: claude --resume {new_uuid}")
        return 0
    if args.cmd == "claude-to-codex":
        src = find_claude_session(args.uuid)
        target, new_uuid = claude_to_codex(
            src,
            target_cwd=args.target_cwd,
            codex_approval_policy=args.codex_approval_policy,
            codex_sandbox_policy=args.codex_sandbox_policy,
        )
        emit(f"converted: {src} -> {target}")
        emit(f"new session UUID: {new_uuid}")
        emit(f"resume with: codex resume {new_uuid}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
