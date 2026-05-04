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
- Tool calls round-trip structurally only when both sides recognize the
  tool; the cross-vendor mapping is deliberately narrow (Bash <->
  exec_command). Unmapped tools fold into descriptive text blocks so the
  receiving model still sees the prior tool history without depending on
  the receiving API to recognize a foreign tool name.
- Reasoning / thinking blocks are dropped on cross-vendor handoff. Both
  vendors store reasoning with cryptographic signatures (Claude
  `signature`, Codex `encrypted_content`) that cannot round-trip across
  vendors; including them causes the receiving API to reject the turn.
- Codex `turn_aborted` markers cause the response_items emitted since the
  most recent `task_started` to be discarded, matching the source model's
  view that those items were never committed.
- Claude `attachment` (hook telemetry) and `file-history-snapshot` records
  are dropped: their information is already present in the corresponding
  `tool_result` content (what the source model actually saw), or is
  Claude Code-internal bookkeeping not load-bearing for conversation
  continuation.
- Source `cwd` is read from the most recent record that carries one;
  runtime cwd at resume time overrides per receiver behavior.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time
import uuid
from pathlib import Path
from typing import Any


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


def gen_uuid_v7() -> str:
    """Return a UUIDv7-shaped string. Falls back to time-prefixed v4 on Python <3.13."""
    fn = getattr(uuid, "uuid7", None)
    if fn is not None:
        return str(fn())
    ts_ms = int(time.time() * 1000)
    ts_hex = f"{ts_ms:012x}"
    rand = secrets.token_hex(10)
    return f"{ts_hex[:8]}-{ts_hex[8:12]}-7{rand[0:3]}-{rand[3:7]}-{rand[7:19]}"


def gen_claude_tool_id() -> str:
    return f"toolu_{secrets.token_urlsafe(16).replace('-', 'A').replace('_', 'B')}"[:30]


def gen_codex_call_id() -> str:
    return f"call_{secrets.token_urlsafe(20).replace('-', 'A').replace('_', 'B')}"[:30]


def encode_claude_project(cwd: str) -> str:
    """Match Claude Code's project directory encoding: replace path separators with dashes."""
    return cwd.replace("/", "-")


_FULL_UUID_RE = __import__("re").compile(
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
    with path.open() as f:
        for lineno, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as exc:
                # Log to stderr so bugs in the source file are surfaced rather
                # than silently dropping data. Conversion still proceeds.
                sys.stderr.write(
                    f"session_convert: warning: skipping malformed JSON line "
                    f"{lineno} in {path}: {exc}\n"
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
        with tmp.open("w") as f:
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
    pending_start: int | None = None
    for i, r in enumerate(records):
        rtype = r.get("type")
        if rtype == "event_msg":
            payload = r.get("payload", {}) if isinstance(r.get("payload"), dict) else {}
            ptype = payload.get("type")
            if ptype == "task_started":
                pending_start = i
            elif ptype == "task_complete":
                pending_start = None
        elif rtype == "turn_aborted":
            if pending_start is not None:
                for j in range(pending_start + 1, i):
                    if records[j].get("type") == "response_item":
                        keep[j] = False
            pending_start = None
    return [r for r, k in zip(records, keep) if k]


def codex_to_claude(src: Path, target_cwd: str | None = None) -> tuple[Path, str]:
    """Convert a Codex rollout to a Claude session. Returns (output path, new uuid)."""
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
    cwd = (
        target_cwd
        or src_cwd_recent
        or session_meta.get("payload", {}).get("cwd")
        or os.getcwd()
    )
    new_uuid = gen_uuid_v7()

    out: list[dict[str, Any]] = []
    parent_uuid: str | None = None
    call_id_to_tool_id: dict[str, str] = {}
    unknown_call_ids: set[str] = set()

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
            "timestamp": now_iso(),
            "isSidechain": False,
            "message": message,
        }
        if extras:
            rec.update(extras)
        parent_uuid = rec_uuid
        return rec

    for r in records:
        rtype = r.get("type")
        payload = r.get("payload", {}) if isinstance(r.get("payload"), dict) else {}
        if rtype == "event_msg" and payload.get("type") == "user_message":
            text = payload.get("message", "")
            if not text:
                continue
            out.append(make_record(
                "user",
                {"role": "user", "content": [{"type": "text", "text": text}]},
            ))
            continue

        if rtype != "response_item":
            continue

        ptype = payload.get("type")
        if ptype == "message" and payload.get("role") == "assistant":
            content_blocks = []
            for block in payload.get("content", []) or []:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                text = block.get("text") or ""
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
            if call_id in unknown_call_ids:
                # Companion fold for an unmapped tool call.
                out.append(make_record(
                    "user",
                    {"role": "user", "content": [{"type": "text",
                                                  "text": f"[Tool result: {output}]"}]},
                ))
                continue
            tool_use_id = call_id_to_tool_id.get(call_id)
            if tool_use_id is None:
                # Orphan output (no matching call). Fold into a user text record.
                if not output:
                    continue
                out.append(make_record(
                    "user",
                    {"role": "user", "content": [{"type": "text", "text": str(output)}]},
                ))
                continue
            out.append(make_record(
                "user",
                {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": tool_use_id, "content": str(output), "is_error": False},
                ]},
            ))
        # Drop reasoning, unknown, and other response_item types.

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
        import subprocess
        res = subprocess.run(
            ["codex", "--version"], capture_output=True, text=True, timeout=2
        )
        if res.returncode == 0:
            # Output is like "OpenAI Codex v0.128.0 (research preview)" or
            # similar. Extract the first vN.N.N-shaped token if present.
            import re
            m = re.search(r"v?(\d+\.\d+\.\d+)", res.stdout)
            if m:
                return m.group(1)
    except (FileNotFoundError, OSError, __import__("subprocess").TimeoutExpired):
        pass
    return "0.0.0-translated"


def claude_to_codex(src: Path, target_cwd: str | None = None) -> tuple[Path, str]:
    """Convert a Claude session to a Codex rollout. Returns (output path, new uuid)."""
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
    cwd = target_cwd or src_cwd or os.getcwd()
    new_uuid = gen_uuid_v7()
    cli_version = _detect_codex_cli_version()

    out: list[dict[str, Any]] = []
    tool_id_to_call_id: dict[str, str] = {}

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
            "approval_policy": "never",
            "sandbox_policy": {"mode": "read-only"},
            "model": "gpt-5.5",
            "effort": "none",
            "summary": "none",
        },
    })

    for r in records:
        rtype = r.get("type")
        message = r.get("message")
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
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
                elif btype == "tool_result":
                    tool_results.append(block)
            if text_parts:
                joined = "\n".join(p for p in text_parts if p)
                if joined.strip():
                    out.append({
                        "timestamp": now_iso(),
                        "type": "event_msg",
                        "payload": {
                            "type": "user_message",
                            "message": joined,
                            "images": [], "local_images": [], "text_elements": [],
                        },
                    })
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
                        "timestamp": now_iso(),
                        "type": "event_msg",
                        "payload": {
                            "type": "user_message",
                            "message": f"[Tool result: {output_str}]",
                            "images": [], "local_images": [], "text_elements": [],
                        },
                    })
                    continue
                if call_id is None:
                    # Orphan tool_result (no matching tool_use seen). Fall
                    # back to a fresh call_id so the rollout still validates.
                    call_id = gen_codex_call_id()
                out.append({
                    "timestamp": now_iso(),
                    "type": "response_item",
                    "payload": {
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": output_str,
                    },
                })
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
                        "timestamp": now_iso(),
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "role": "assistant",
                            "content": [{"type": "output_text", "text": joined}],
                            "phase": "commentary",
                        },
                    })
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
                        "timestamp": now_iso(),
                        "type": "response_item",
                        "payload": {
                            "type": "function_call",
                            "name": tool_name_codex,
                            "arguments": json.dumps(args),
                            "call_id": call_id,
                        },
                    })
                else:
                    # Fold unmapped Claude tool into Codex assistant text. Codex
                    # may not accept arbitrary tool names from a foreign tool
                    # schema, so this stays in the narrative as text.
                    tool_id_to_call_id[tool_use_id] = "__unmapped__"
                    preview = json.dumps(input_obj) if isinstance(input_obj, (dict, list)) else str(input_obj)
                    out.append({
                        "timestamp": now_iso(),
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "role": "assistant",
                            "content": [{"type": "output_text",
                                         "text": f"[Used Claude tool `{tool_name_claude}` with input: {preview}]"}],
                            "phase": "commentary",
                        },
                    })
        # Drop attachment, file-history-snapshot, system, queue-operation, etc.

    target_path = codex_rollout_path(new_uuid)
    write_jsonl(target_path, out)
    return target_path, new_uuid


def _normalize_tool_input_to_codex(tool_name: str, input_obj: dict[str, Any], cwd: str) -> dict[str, Any]:
    if tool_name == "Bash":
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
    parser = argparse.ArgumentParser(prog="session_convert", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_c2c = sub.add_parser("codex-to-claude", help="Convert a Codex rollout into a Claude session")
    p_c2c.add_argument("uuid", help="Codex session UUID (full or partial)")
    p_c2c.add_argument("--target-cwd", help="Override cwd for the converted session")

    p_cc2 = sub.add_parser("claude-to-codex", help="Convert a Claude session into a Codex rollout")
    p_cc2.add_argument("uuid", help="Claude session UUID (full or partial)")
    p_cc2.add_argument("--target-cwd", help="Override cwd for the converted session")

    args = parser.parse_args(argv)

    def emit(line: str) -> None:
        sys.stdout.write(line + "\n")

    if args.cmd == "codex-to-claude":
        src = find_codex_session(args.uuid)
        target, new_uuid = codex_to_claude(src, target_cwd=args.target_cwd)
        emit(f"converted: {src} -> {target}")
        emit(f"new session UUID: {new_uuid}")
        emit(f"resume with: claude --resume {new_uuid}")
        return 0
    if args.cmd == "claude-to-codex":
        src = find_claude_session(args.uuid)
        target, new_uuid = claude_to_codex(src, target_cwd=args.target_cwd)
        emit(f"converted: {src} -> {target}")
        emit(f"new session UUID: {new_uuid}")
        emit(f"resume with: codex resume {new_uuid}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
