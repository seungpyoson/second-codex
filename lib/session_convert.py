#!/usr/bin/env python3
"""Bidirectional session-state converters between Claude Code and Codex CLI.

Reads a source-format session JSONL and emits the equivalent target-format
JSONL at the target tool's canonical session path. The target tool's native
resume command (`claude --resume <uuid>` or `codex resume <uuid>`) then loads
the converted session as if it were native.

The conversion is content-preserving for text messages and tool calls. It
drops reasoning/thinking blocks (cross-vendor reasoning provenance does not
round-trip), attachments (Claude Code-specific hook output, folded into
preceding tool_result text), and file-history-snapshots (non-essential).

Subcommands:
  codex-to-claude <codex-uuid> [--target-cwd <path>]
  claude-to-codex <claude-uuid> [--target-cwd <path>]

Each prints the new session UUID on success; resume the converted session
with the target tool's native command.
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


# Tool name mapping. Maps are intentionally narrow; unmapped tools fall back
# to a stub-as-text representation rather than fabricating a target tool.
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


def find_codex_session(uuid_partial: str) -> Path:
    bases = _codex_session_bases()
    matches = []
    for base in bases:
        if not base.exists():
            continue
        for path in base.rglob("rollout-*.jsonl"):
            if uuid_partial in path.name:
                matches.append(path)
    if not matches:
        raise FileNotFoundError(f"No Codex rollout matching '{uuid_partial}' under {bases}")
    if len(matches) > 1:
        raise ValueError(f"Ambiguous Codex UUID '{uuid_partial}': matches {len(matches)} files")
    return matches[0]


def find_claude_session(uuid_partial: str) -> Path:
    base = _claude_projects_base()
    if not base.exists():
        raise FileNotFoundError(f"Claude projects directory missing: {base}")
    matches = []
    for project in base.iterdir():
        if not project.is_dir():
            continue
        for path in project.glob("*.jsonl"):
            if uuid_partial in path.name:
                matches.append(path)
    if not matches:
        raise FileNotFoundError(f"No Claude session matching '{uuid_partial}' under {base}")
    if len(matches) > 1:
        raise ValueError(f"Ambiguous Claude UUID '{uuid_partial}': matches {len(matches)} files")
    return matches[0]


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    out = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


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


def codex_to_claude(src: Path, target_cwd: str | None = None) -> tuple[Path, str]:
    """Convert a Codex rollout to a Claude session. Returns (output path, new uuid)."""
    records = read_jsonl(src)
    session_meta = next((r for r in records if r.get("type") == "session_meta"), None)
    if session_meta is None:
        raise ValueError(f"Source has no session_meta record: {src}")

    cwd = target_cwd or session_meta.get("payload", {}).get("cwd") or os.getcwd()
    new_uuid = gen_uuid_v7()

    out: list[dict[str, Any]] = []
    parent_uuid: str | None = None
    call_id_to_tool_id: dict[str, str] = {}

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
            tool_name_claude = CODEX_TO_CLAUDE_TOOL.get(tool_name_codex, tool_name_codex)
            args_str = payload.get("arguments", "{}")
            try:
                args = json.loads(args_str) if isinstance(args_str, str) else args_str
            except json.JSONDecodeError:
                args = {"raw_arguments": args_str}
            tool_use_id = gen_claude_tool_id()
            call_id_to_tool_id[call_id] = tool_use_id
            # Emit assistant record carrying a tool_use block.
            out.append(make_record(
                "assistant",
                {
                    "id": f"msg_xfmt_{secrets.token_hex(8)}",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-opus-4-7",
                    "content": [
                        {"type": "tool_use", "id": tool_use_id, "name": tool_name_claude, "input": _normalize_tool_input(tool_name_claude, args)},
                    ],
                    "stop_reason": "tool_use",
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
                extras={"requestId": f"req_xfmt_{secrets.token_hex(8)}"},
            ))
        elif ptype == "function_call_output":
            call_id = payload.get("call_id", "")
            tool_use_id = call_id_to_tool_id.get(call_id)
            if tool_use_id is None:
                # Orphan output (no matching call). Fold into a user text record.
                content = payload.get("output", "")
                if not content:
                    continue
                out.append(make_record(
                    "user",
                    {"role": "user", "content": [{"type": "text", "text": str(content)}]},
                ))
                continue
            output = payload.get("output", "")
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


def claude_to_codex(src: Path, target_cwd: str | None = None) -> tuple[Path, str]:
    """Convert a Claude session to a Codex rollout. Returns (output path, new uuid)."""
    records = read_jsonl(src)
    if not records:
        raise ValueError(f"Source is empty: {src}")

    # Pick cwd from first record that has one, or fall back.
    src_cwd = next((r.get("cwd") for r in records if r.get("cwd")), os.getcwd())
    cwd = target_cwd or src_cwd
    new_uuid = gen_uuid_v7()

    out: list[dict[str, Any]] = []
    tool_id_to_call_id: dict[str, str] = {}

    out.append({
        "timestamp": now_iso(),
        "type": "session_meta",
        "payload": {
            "id": new_uuid,
            "timestamp": now_iso(),
            "cwd": cwd,
            "originator": "second-codex-handoff",
            "cli_version": "0.0.0",
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
                call_id = tool_id_to_call_id.get(tool_use_id, gen_codex_call_id())
                output = tr.get("content")
                if isinstance(output, list):
                    output = "\n".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in output)
                output_str = str(output or "")
                if tr.get("is_error"):
                    output_str = f"[error]\n{output_str}"
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
                tool_name_codex = CLAUDE_TO_CODEX_TOOL.get(tool_name_claude, tool_name_claude.lower())
                input_obj = tu.get("input") or {}
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
