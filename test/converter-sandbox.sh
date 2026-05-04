#!/usr/bin/env bash
set -euo pipefail

# Structural test for lib/session_convert.py.
# Builds synthetic source sessions in an isolated sandbox, runs the converter
# in both directions, and asserts the output JSONL has the expected shape.
# Does NOT call any LLM API.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-converter-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

CODEX_HOME="$SANDBOX/codex"
CLAUDE_HOME="$SANDBOX/claude"
CWD="/tmp/sandbox-project"
# Encode the sandbox CWD using the converter's actual rule (realpath then
# strip non-alphanumeric-non-dash). On macOS /tmp realpath-resolves to
# /private/tmp; the converter writes to the realpath-encoded dir so that
# `claude --resume` (which also realpaths) finds the file.
encode_claude_dir() { python3 -c 'import os, re, sys; print(re.sub(r"[^A-Za-z0-9-]", "-", os.path.realpath(sys.argv[1])))' "$1"; }
ENCODED_CWD="$(encode_claude_dir "$CWD")"
mkdir -p "$CODEX_HOME/sessions/2026/05/04"
mkdir -p "$CLAUDE_HOME/projects/$ENCODED_CWD"

# ---------------------------------------------------------------------------
# Build a synthetic Codex source rollout (text + tool call).
# ---------------------------------------------------------------------------
CODEX_SRC_UUID="00000000-0000-7000-8000-00000000000a"
CODEX_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-$CODEX_SRC_UUID.jsonl"
cat > "$CODEX_SRC" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CODEX_SRC_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Show file count","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Counting now"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls\",\"workdir\":\"$CWD\"}","call_id":"call_TESTfixed01"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_TESTfixed01","output":"file_a\nfile_b\nfile_c"}}
{"timestamp":"2026-05-04T00:00:06.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Three files."}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:07.000Z","type":"response_item","payload":{"type":"reasoning","content":[],"summary":[],"encrypted_content":"OPAQUE_REASONING_CONTENT"}}
EOF

# ---------------------------------------------------------------------------
# codex-to-claude
# ---------------------------------------------------------------------------
OUT="$SANDBOX/c2c.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$CODEX_SRC_UUID" >"$OUT" 2>&1
grep -q "^new session UUID:" "$OUT"
NEW_CLAUDE_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
NEW_CLAUDE_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$NEW_CLAUDE_UUID.jsonl"
[ -f "$NEW_CLAUDE_PATH" ] || { echo "FAIL converter did not write $NEW_CLAUDE_PATH"; exit 1; }

# Assert structural properties of the converted Claude session.
python3 - <<EOF
import json, sys
records = [json.loads(l) for l in open("$NEW_CLAUDE_PATH") if l.strip()]
assert records, "converted session is empty"

# First record must be a user message linking to nothing.
assert records[0]["type"] == "user", f"first record type {records[0]['type']!r}"
assert records[0]["parentUuid"] is None, "first record parentUuid should be None"
assert records[0]["sessionId"] == "$NEW_CLAUDE_UUID", "sessionId mismatch"

# The whole chain must be parentUuid-linked.
prev_uuid = None
for r in records:
    assert r["parentUuid"] == prev_uuid, f"parentUuid chain broken at {r['uuid']!r}"
    prev_uuid = r["uuid"]
    assert r["sessionId"] == "$NEW_CLAUDE_UUID", "sessionId not propagated"

# Tool call must appear as tool_use block in an assistant record.
tool_use_seen = False
tool_use_id = None
for r in records:
    if r["type"] != "assistant":
        continue
    for block in r["message"]["content"]:
        if block.get("type") == "tool_use":
            tool_use_seen = True
            assert block["name"] == "Bash", f"tool name not remapped: {block['name']!r}"
            assert "command" in block["input"], "Bash input missing 'command'"
            assert block["input"]["command"] == "ls", f"command mistranslated: {block['input']['command']!r}"
            tool_use_id = block["id"]
            assert tool_use_id.startswith("toolu_"), f"tool id prefix wrong: {tool_use_id!r}"
assert tool_use_seen, "no tool_use block in converted session"

# Tool result must reference the same tool_use_id.
tool_result_seen = False
for r in records:
    if r["type"] != "user":
        continue
    for block in r["message"]["content"]:
        if block.get("type") == "tool_result":
            tool_result_seen = True
            assert block["tool_use_id"] == tool_use_id, "tool_use_id linkage broken"
            assert "file_a" in block["content"], "tool result content missing"
assert tool_result_seen, "no tool_result block in converted session"

# Reasoning must be dropped (cross-vendor unforgeable).
for r in records:
    if r["type"] == "assistant":
        for block in r["message"]["content"]:
            assert block.get("type") != "thinking", "reasoning should be dropped on cross-vendor"

print("codex-to-claude structural test PASSED")
EOF

# ---------------------------------------------------------------------------
# Build a synthetic Claude source session (text + tool call) for reverse direction.
# ---------------------------------------------------------------------------
CLAUDE_SRC_UUID="00000000-0000-4000-8000-00000000000c"
CLAUDE_SRC="$CLAUDE_HOME/projects/$ENCODED_CWD/$CLAUDE_SRC_UUID.jsonl"
cat > "$CLAUDE_SRC" <<'EOF'
{"type":"user","uuid":"u1","parentUuid":null,"sessionId":"00000000-0000-4000-8000-00000000000c","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:00.000Z","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"List files"}]}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"00000000-0000-4000-8000-00000000000c","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:01.000Z","isSidechain":false,"requestId":"req_t","message":{"id":"m1","type":"message","role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"OK"},{"type":"tool_use","id":"toolu_TESTfixed01","name":"Bash","input":{"command":"ls","description":"List"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":10}}}
{"type":"user","uuid":"u2","parentUuid":"a1","sessionId":"00000000-0000-4000-8000-00000000000c","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:02.000Z","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_TESTfixed01","content":"file_a\nfile_b","is_error":false}]}}
{"type":"assistant","uuid":"a2","parentUuid":"u2","sessionId":"00000000-0000-4000-8000-00000000000c","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:03.000Z","isSidechain":false,"requestId":"req_t2","message":{"id":"m2","type":"message","role":"assistant","model":"claude-opus-4-7","content":[{"type":"thinking","thinking":"","signature":"OPAQUE_SIGNATURE"},{"type":"text","text":"Two files."}],"stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":10}}}
{"type":"attachment","uuid":"at1","parentUuid":"a2","sessionId":"00000000-0000-4000-8000-00000000000c","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:04.000Z","isSidechain":false,"attachment":{"type":"hook","hookName":"PreToolUse","command":"echo","stdout":"","stderr":"","exitCode":0,"durationMs":1,"hookEvent":"PreToolUse","content":"","toolUseID":"toolu_TESTfixed01"}}
EOF

# ---------------------------------------------------------------------------
# claude-to-codex
# ---------------------------------------------------------------------------
OUT="$SANDBOX/cc2.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$CLAUDE_SRC_UUID" >"$OUT" 2>&1
grep -q "^new session UUID:" "$OUT"
NEW_CODEX_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
NEW_CODEX_PATH="$(grep '^converted:' "$OUT" | awk -F'-> ' '{print $2}')"
[ -f "$NEW_CODEX_PATH" ] || { echo "FAIL converter did not write $NEW_CODEX_PATH"; exit 1; }

python3 - <<EOF
import json, sys
records = [json.loads(l) for l in open("$NEW_CODEX_PATH") if l.strip()]
assert records, "converted rollout is empty"

# First record must be session_meta with the new UUID.
assert records[0]["type"] == "session_meta", f"first record type {records[0]['type']!r}"
assert records[0]["payload"]["id"] == "$NEW_CODEX_UUID", "session_meta UUID mismatch"

# Second record must be turn_context.
assert records[1]["type"] == "turn_context", f"second record type {records[1]['type']!r}"

# A user_message event must exist with the expected text.
um = [r for r in records if r["type"] == "event_msg" and r["payload"].get("type") == "user_message"]
assert um, "no user_message event in converted rollout"
assert um[0]["payload"]["message"] == "List files", "user_message text wrong"

# A function_call must exist with proper shape.
fc = [r for r in records if r["type"] == "response_item" and r["payload"].get("type") == "function_call"]
assert fc, "no function_call in converted rollout"
assert fc[0]["payload"]["name"] == "exec_command", f"tool name not remapped: {fc[0]['payload']['name']!r}"
args = json.loads(fc[0]["payload"]["arguments"])
assert args.get("cmd") == "ls", f"cmd field wrong: {args!r}"
assert fc[0]["payload"]["call_id"].startswith("call_"), "call_id prefix wrong"

# function_call_output must exist linking to the same call_id.
fco = [r for r in records if r["type"] == "response_item" and r["payload"].get("type") == "function_call_output"]
assert fco, "no function_call_output in converted rollout"
assert fco[0]["payload"]["call_id"] == fc[0]["payload"]["call_id"], "call_id linkage broken"
assert "file_a" in fco[0]["payload"]["output"], "tool output content missing"

# Thinking block from source must NOT round-trip into Codex (cross-vendor signatures unforgeable).
for r in records:
    if r["type"] == "response_item" and r["payload"].get("type") == "reasoning":
        # If a reasoning block leaked through, encrypted_content must not be the source's signature.
        assert r["payload"].get("encrypted_content") != "OPAQUE_SIGNATURE", "thinking signature leaked across vendors"

# Attachment record (Claude hook output) must be dropped.
for r in records:
    assert r["type"] != "attachment", "attachment record leaked into Codex rollout"

print("claude-to-codex structural test PASSED")
EOF

# ---------------------------------------------------------------------------
# Bash wrapper smoke tests: exercise the second-codex subcommands.
# ---------------------------------------------------------------------------

# usage / arg-parsing tests do not need the converter to run.
"$REPO_ROOT/second-codex" handoff-to-claude >"$SANDBOX/usage1.out" 2>&1 && {
  echo "FAIL handoff-to-claude with no args should fail"; exit 1; }
grep -q "^usage: second-codex handoff-to-claude" "$SANDBOX/usage1.out"

"$REPO_ROOT/second-codex" handoff-from-claude >"$SANDBOX/usage2.out" 2>&1 && {
  echo "FAIL handoff-from-claude with no args should fail"; exit 1; }
grep -q "^usage: second-codex handoff-from-claude" "$SANDBOX/usage2.out"

"$REPO_ROOT/second-codex" handoff-to-claude bogus-id >"$SANDBOX/usage3.out" 2>&1 && {
  echo "FAIL malformed session id should be rejected"; exit 1; }
grep -q "refused malformed session id" "$SANDBOX/usage3.out"

"$REPO_ROOT/second-codex" handoff-to-claude --bad-flag >"$SANDBOX/usage4.out" 2>&1 && {
  echo "FAIL flag-shaped arg should be rejected"; exit 1; }
grep -q "^usage: second-codex handoff-to-claude" "$SANDBOX/usage4.out"

# python3-missing path: helper must surface a clear error without crashing.
SECOND_CODEX_TEST_DISABLE_PYTHON3=1 \
  "$REPO_ROOT/second-codex" handoff-to-claude "$CODEX_SRC_UUID" >"$SANDBOX/no-python.out" 2>&1 && {
  echo "FAIL handoff-to-claude should refuse to run without python3"; exit 1; }
grep -q "requires python3" "$SANDBOX/no-python.out"

# Round-trip via the bash wrapper using the sandbox CODEX_HOME / CLAUDE_HOME.
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  "$REPO_ROOT/second-codex" handoff-to-claude "$CODEX_SRC_UUID" >"$SANDBOX/wrap-c2c.out" 2>&1
grep -q "^new session UUID:" "$SANDBOX/wrap-c2c.out"

CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  "$REPO_ROOT/second-codex" handoff-from-claude "$CLAUDE_SRC_UUID" >"$SANDBOX/wrap-cc2.out" 2>&1
grep -q "^new session UUID:" "$SANDBOX/wrap-cc2.out"

echo "bash wrapper smoke tests PASSED"

# ---------------------------------------------------------------------------
# Round-trip A -> B -> A: a Codex session converts to Claude, then that
# Claude session converts back to Codex. Content from the original turns
# must survive both hops.
# ---------------------------------------------------------------------------
RT_CODEX_UUID="00000000-0000-7000-8000-000000000020"
RT_CODEX="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-02-00-$RT_CODEX_UUID.jsonl"
cat > "$RT_CODEX" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$RT_CODEX_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Round-trip marker text: pumpkin-orbit-7711","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Acknowledged the round-trip marker."}],"phase":"commentary"}}
EOF

CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$RT_CODEX_UUID" >"$SANDBOX/rt1.out" 2>&1
RT_CLAUDE_UUID="$(grep '^new session UUID:' "$SANDBOX/rt1.out" | awk '{print $NF}')"

CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$RT_CLAUDE_UUID" >"$SANDBOX/rt2.out" 2>&1
RT_CODEX2_PATH="$(grep '^converted:' "$SANDBOX/rt2.out" | awk -F'-> ' '{print $2}')"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$RT_CODEX2_PATH") if l.strip()]
joined = ""
for r in records:
    pl = r.get("payload", {})
    pt = pl.get("type") if isinstance(pl, dict) else None
    if pt == "user_message":
        joined += pl.get("message", "")
    elif pt == "message":
        for b in pl.get("content", []):
            if isinstance(b, dict) and b.get("type") == "output_text":
                joined += b.get("text", "")
assert "pumpkin-orbit-7711" in joined, "round-trip lost the user marker"
assert "Acknowledged the round-trip marker" in joined, "round-trip lost the assistant turn"
print("round-trip A->B->A PASSED")
EOF

# ---------------------------------------------------------------------------
# turn_aborted: response_items between task_started and turn_aborted must
# be dropped on conversion (the source model treated them as abandoned).
# ---------------------------------------------------------------------------
TA_UUID="00000000-0000-7000-8000-000000000021"
TA_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-03-00-$TA_UUID.jsonl"
cat > "$TA_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TA_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"First user turn","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ABANDONED-CONTENT-DO-NOT-RECALL"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"turn_aborted"}
{"timestamp":"2026-05-04T00:00:06.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-05-04T00:00:07.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"COMMITTED-RESPONSE-PUMPKIN"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:08.000Z","type":"event_msg","payload":{"type":"task_complete"}}
EOF

OUT="$SANDBOX/ta.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TA_UUID" >"$OUT" 2>&1
TA_CLAUDE_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TA_CLAUDE_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TA_CLAUDE_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TA_CLAUDE_PATH") if l.strip()]
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
assert "ABANDONED-CONTENT-DO-NOT-RECALL" not in joined, "abandoned content leaked into converted session"
assert "COMMITTED-RESPONSE-PUMPKIN" in joined, "committed turn was wrongly dropped"
print("turn_aborted handling PASSED")
EOF

# ---------------------------------------------------------------------------
# Atomicity: write_jsonl uses tmp+rename. The temp file should not exist
# after a successful conversion, and the target file should be present.
# ---------------------------------------------------------------------------
TARGET_DIR="$CLAUDE_HOME/projects/$ENCODED_CWD"
LEFTOVERS="$(find "$TARGET_DIR" -name '*.tmp' 2>/dev/null | head -1)"
if [ -n "$LEFTOVERS" ]; then
    echo "FAIL: temp files left after successful conversions: $LEFTOVERS"
    exit 1
fi
echo "atomic-write residue check PASSED"

# ---------------------------------------------------------------------------
# UUID validation: bare strings, partial UUIDs, and empty input must be
# rejected with a clear error before any filesystem access.
# ---------------------------------------------------------------------------
if python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "" >"$SANDBOX/uuid-empty.out" 2>&1; then
    echo "FAIL: empty UUID should be rejected"; exit 1
fi
grep -q "must be a full UUID" "$SANDBOX/uuid-empty.out"

if python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "abcd" >"$SANDBOX/uuid-short.out" 2>&1; then
    echo "FAIL: short UUID should be rejected"; exit 1
fi
grep -q "must be a full UUID" "$SANDBOX/uuid-short.out"
echo "UUID validation PASSED"

# ---------------------------------------------------------------------------
# --help / --target-cwd via the bash wrapper.
# ---------------------------------------------------------------------------
"$REPO_ROOT/second-codex" handoff-to-claude --help >"$SANDBOX/help.out" 2>&1
grep -q "^usage: second-codex handoff-to-claude" "$SANDBOX/help.out"

# Use a fresh codex source for the --target-cwd test so we can assert the
# converted Claude session lands under the override path.
CT_UUID="00000000-0000-7000-8000-000000000022"
CT_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-04-00-$CT_UUID.jsonl"
cat > "$CT_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CT_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"placeholder","images":[],"local_images":[],"text_elements":[]}}
EOF

OVERRIDE_CWD="/tmp/sandbox-override-target"
ENCODED_OVERRIDE="$(encode_claude_dir "$OVERRIDE_CWD")"
mkdir -p "$CLAUDE_HOME/projects/$ENCODED_OVERRIDE"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  "$REPO_ROOT/second-codex" handoff-to-claude "$CT_UUID" --target-cwd "$OVERRIDE_CWD" >"$SANDBOX/ct.out" 2>&1
CT_PRODUCED="$(grep '^converted:' "$SANDBOX/ct.out" | awk -F'-> ' '{print $2}')"
case "$CT_PRODUCED" in
    *"$ENCODED_OVERRIDE"*) : ;;
    *) echo "FAIL: --target-cwd not honored: $CT_PRODUCED"; exit 1 ;;
esac
echo "wrapper --help / --target-cwd PASSED"

# ---------------------------------------------------------------------------
# J: top-level task_started / turn_aborted (no event_msg wrapper).
# Some Codex rollouts emit task_started as a top-level type rather than
# nested in event_msg.payload. The abort filter must recognize either form.
# ---------------------------------------------------------------------------
TJ_UUID="00000000-0000-7000-8000-000000000023"
TJ_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-05-00-$TJ_UUID.jsonl"
cat > "$TJ_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TJ_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"User turn","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"task_started"}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"TOPLEVEL-ABANDONED-DO-NOT-RECALL"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"turn_aborted"}
{"timestamp":"2026-05-04T00:00:06.000Z","type":"task_started"}
{"timestamp":"2026-05-04T00:00:07.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"TOPLEVEL-COMMITTED-MARMALADE"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:08.000Z","type":"task_complete"}
EOF

OUT="$SANDBOX/topabort.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TJ_UUID" >"$OUT" 2>&1
TJ_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TJ_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TJ_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TJ_NEW_PATH") if l.strip()]
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
assert "TOPLEVEL-ABANDONED-DO-NOT-RECALL" not in joined, "top-level turn_aborted not honored"
assert "TOPLEVEL-COMMITTED-MARMALADE" in joined, "top-level committed turn was wrongly dropped"
print("top-level task_started / turn_aborted PASSED")
EOF

# ---------------------------------------------------------------------------
# H: unicode round-trip. Source content with emoji and CJK must survive
# without being escaped to \uXXXX sequences in the converted file.
# ---------------------------------------------------------------------------
TH_UUID="00000000-0000-7000-8000-000000000024"
TH_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-06-00-$TH_UUID.jsonl"
cat > "$TH_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TH_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"unicode marker 🍊 漢字 ✅","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"echo back: 🍊 漢字 ✅"}],"phase":"commentary"}}
EOF

OUT="$SANDBOX/unicode.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TH_UUID" >"$OUT" 2>&1
TH_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TH_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TH_NEW_UUID.jsonl"

# Bytes on disk must be the unescaped UTF-8, not \uXXXX escape sequences.
if grep -q '\\\\u' "$TH_NEW_PATH"; then
    echo "FAIL: unicode escapes leaked into converted session ($TH_NEW_PATH)"
    exit 1
fi
grep -q '🍊' "$TH_NEW_PATH"
grep -q '漢字' "$TH_NEW_PATH"
echo "unicode round-trip PASSED"

# ---------------------------------------------------------------------------
# I: malformed JSON warning is emitted to stderr (and conversion proceeds).
# ---------------------------------------------------------------------------
TI_UUID="00000000-0000-7000-8000-000000000025"
TI_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-07-00-$TI_UUID.jsonl"
cat > "$TI_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TI_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{this is not valid json on a single line
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"survived","images":[],"local_images":[],"text_elements":[]}}
EOF

CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TI_UUID" >"$SANDBOX/malformed.stdout" 2>"$SANDBOX/malformed.stderr"
TI_NEW_UUID="$(grep '^new session UUID:' "$SANDBOX/malformed.stdout" | awk '{print $NF}')"
TI_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TI_NEW_UUID.jsonl"
grep -q "warning: skipping malformed JSON line" "$SANDBOX/malformed.stderr"
grep -q "JSONDecodeError" "$SANDBOX/malformed.stderr"
# stderr should NOT echo the offending line content (privacy: avoid leaking
# source bytes). The bad line we wrote contains the literal substring "this".
if grep -q "this is not valid json" "$SANDBOX/malformed.stderr"; then
    echo "FAIL: malformed-line content leaked to stderr"
    exit 1
fi
# The valid line ("survived") must still convert into the output.
grep -q "survived" "$TI_NEW_PATH"
echo "malformed JSON warning PASSED"

# ---------------------------------------------------------------------------
# Unmapped-tool fold: tool calls without a known cross-format mapping must
# render as descriptive text rather than emit a function_call/tool_use the
# receiver may reject as an unknown tool name.
# ---------------------------------------------------------------------------

# Codex source with an unknown tool (web_search_call).
CODEX_UNMAPPED_UUID="00000000-0000-7000-8000-00000000000d"
CODEX_UNMAPPED="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-01-00-$CODEX_UNMAPPED_UUID.jsonl"
cat > "$CODEX_UNMAPPED" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CODEX_UNMAPPED_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Search the web","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"web_search_call","arguments":"{\"query\":\"hello\"}","call_id":"call_UNMAPPED1"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_UNMAPPED1","output":"hello world"}}
EOF

OUT="$SANDBOX/c2c-unmapped.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$CODEX_UNMAPPED_UUID" >"$OUT" 2>&1
NEW_CLAUDE_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
NEW_CLAUDE_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$NEW_CLAUDE_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$NEW_CLAUDE_PATH") if l.strip()]
# No tool_use blocks should appear (web_search_call is unmapped).
for r in records:
    if r["type"] != "assistant":
        continue
    for block in r["message"]["content"]:
        assert block.get("type") != "tool_use", "unmapped tool should fold to text, got tool_use"
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
assert "web_search_call" in joined, "unmapped tool name should appear in folded text"
assert "hello world" in joined, "unmapped tool result should appear in folded text"
print("codex-to-claude unmapped-tool fold PASSED")
EOF

# Claude source with an unknown tool (Glob).
CLAUDE_UNMAPPED_UUID="00000000-0000-4000-8000-00000000000e"
CLAUDE_UNMAPPED="$CLAUDE_HOME/projects/$ENCODED_CWD/$CLAUDE_UNMAPPED_UUID.jsonl"
cat > "$CLAUDE_UNMAPPED" <<'EOF'
{"type":"user","uuid":"u1","parentUuid":null,"sessionId":"00000000-0000-4000-8000-00000000000e","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:00.000Z","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"Find files"}]}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"00000000-0000-4000-8000-00000000000e","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:01.000Z","isSidechain":false,"requestId":"req_t","message":{"id":"m1","type":"message","role":"assistant","model":"claude-opus-4-7","content":[{"type":"tool_use","id":"toolu_UNMAPPED1","name":"Glob","input":{"pattern":"*.py"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":10}}}
{"type":"user","uuid":"u2","parentUuid":"a1","sessionId":"00000000-0000-4000-8000-00000000000e","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:02.000Z","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_UNMAPPED1","content":"a.py b.py","is_error":false}]}}
EOF

OUT="$SANDBOX/cc2-unmapped.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$CLAUDE_UNMAPPED_UUID" >"$OUT" 2>&1
NEW_CODEX_PATH="$(grep '^converted:' "$OUT" | awk -F'-> ' '{print $2}')"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$NEW_CODEX_PATH") if l.strip()]
# No function_call records should be emitted for an unmapped Claude tool.
for r in records:
    if r["type"] == "response_item" and r["payload"].get("type") == "function_call":
        assert r["payload"]["name"] != "glob", "unmapped Claude tool leaked as function_call with lowercased name"
        assert r["payload"]["name"] in ("exec_command",), f"unexpected function_call name: {r['payload']['name']!r}"
joined = ""
for r in records:
    pl = r.get("payload", {})
    if pl.get("type") == "message":
        for b in pl.get("content", []):
            if isinstance(b, dict) and b.get("type") == "output_text":
                joined += b.get("text", "")
    elif pl.get("type") == "user_message":
        joined += pl.get("message", "")
assert "Glob" in joined, "unmapped Claude tool name should appear in folded text"
assert "a.py" in joined, "unmapped Claude tool result should appear in folded text"
print("claude-to-codex unmapped-tool fold PASSED")
EOF

# ---------------------------------------------------------------------------
# K (R1): turn_aborted nested in event_msg.payload.type. Empirical corpus
# scan: 501 real rollouts contain 535 nested turn_aborted, 0 top-level. The
# original test only exercised the top-level form, so the abort filter was
# a no-op on real data and abandoned content leaked through.
# ---------------------------------------------------------------------------
TK_UUID="00000000-0000-7000-8000-000000000026"
TK_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-08-00-$TK_UUID.jsonl"
cat > "$TK_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TK_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"User turn","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"NESTED-ABANDONED-DO-NOT-RECALL"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"event_msg","payload":{"type":"turn_aborted"}}
{"timestamp":"2026-05-04T00:00:06.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-05-04T00:00:07.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"NESTED-COMMITTED-CHESTNUT"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:08.000Z","type":"event_msg","payload":{"type":"task_complete"}}
EOF

OUT="$SANDBOX/nested-abort.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TK_UUID" >"$OUT" 2>&1
TK_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TK_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TK_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TK_NEW_PATH") if l.strip()]
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
assert "NESTED-ABANDONED-DO-NOT-RECALL" not in joined, "nested turn_aborted not honored — abort filter is non-functional on real Codex rollouts"
assert "NESTED-COMMITTED-CHESTNUT" in joined, "nested-form committed turn was wrongly dropped"
print("nested turn_aborted PASSED")
EOF

# ---------------------------------------------------------------------------
# L (R2): UTF-8 round-trip under PYTHONUTF8=0 LC_ALL=C. Default open() uses
# locale-driven encoding; pinning encoding="utf-8" removes the dependency
# so emoji/CJK survive on hosts where the locale is C/POSIX without UTF-8
# mode.
# ---------------------------------------------------------------------------
TL_UUID="00000000-0000-7000-8000-000000000027"
TL_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-09-00-$TL_UUID.jsonl"
cat > "$TL_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TL_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"locale test 🌶 漢字","images":[],"local_images":[],"text_elements":[]}}
EOF

OUT="$SANDBOX/locale.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  PYTHONUTF8=0 LC_ALL=C \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TL_UUID" >"$OUT" 2>"$SANDBOX/locale.err" || {
    echo "FAIL: converter crashed under PYTHONUTF8=0 LC_ALL=C; locale-dependent open() bug not fixed"
    cat "$SANDBOX/locale.err"
    exit 1
  }
TL_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TL_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TL_NEW_UUID.jsonl"
grep -q '🌶' "$TL_NEW_PATH" || { echo "FAIL: emoji not preserved under C locale"; exit 1; }
grep -q '漢字' "$TL_NEW_PATH" || { echo "FAIL: CJK not preserved under C locale"; exit 1; }
echo "UTF-8 round-trip under C locale PASSED"

# ---------------------------------------------------------------------------
# M (R3): README documents the new subcommands. The PR adds two user-facing
# entry points; shipping them undocumented makes them undiscoverable.
# ---------------------------------------------------------------------------
grep -q 'handoff-to-claude' "$REPO_ROOT/README.md" || {
  echo "FAIL: README.md does not document handoff-to-claude"; exit 1; }
grep -q 'handoff-from-claude' "$REPO_ROOT/README.md" || {
  echo "FAIL: README.md does not document handoff-from-claude"; exit 1; }
echo "README documents new subcommands PASSED"

# ---------------------------------------------------------------------------
# N (R4): relative --target-cwd resolves to an absolute path before
# encoding. Without resolve, "../foo" gets encoded as the literal directory
# "..-foo" under the projects base, where Claude resume cannot find it from
# any other working directory.
# ---------------------------------------------------------------------------
TN_UUID="00000000-0000-7000-8000-000000000028"
TN_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-10-00-$TN_UUID.jsonl"
cat > "$TN_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TN_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"placeholder","images":[],"local_images":[],"text_elements":[]}}
EOF

mkdir -p "$SANDBOX/sub-target"
# Compute expected encoding using the same realpath() + non-alphanumeric-
# dash strip the converter uses (Class F empirical fix: claude --resume
# resolves cwd via realpath before encoding, so the converter must too).
EXPECTED_ENC="$( cd "$SANDBOX" && python3 -c 'import os, re, sys
real = os.path.realpath(os.path.expanduser(sys.argv[1]))
print(re.sub(r"[^A-Za-z0-9-]", "-", real))' "../sub-target" )"
LITERAL_ENC="..-sub-target"

OUT="$SANDBOX/rel-cwd.out"
( cd "$SANDBOX" && \
  CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TN_UUID" --target-cwd "../sub-target" >"$OUT" 2>&1 )
TN_NEW_PATH="$(grep '^converted:' "$OUT" | awk -F'-> ' '{print $2}')"
case "$TN_NEW_PATH" in
    *"$LITERAL_ENC"*) echo "FAIL: relative --target-cwd not resolved (literal '..-' leaked into projects dir): $TN_NEW_PATH"; exit 1 ;;
    *"$EXPECTED_ENC"*) : ;;
    *) echo "FAIL: relative --target-cwd produced unexpected output: $TN_NEW_PATH (expected to contain $EXPECTED_ENC)"; exit 1 ;;
esac
echo "relative --target-cwd resolves to absolute PASSED"

# ---------------------------------------------------------------------------
# O (R5): bash wrapper rejects empty --target-cwd value. The flag-shape
# check ([[ "$2" == -* ]]) does not catch empty string, so user input is
# silently ignored and the converter falls through to source/runtime cwd.
# ---------------------------------------------------------------------------
"$REPO_ROOT/second-codex" handoff-to-claude "$CODEX_SRC_UUID" --target-cwd "" >"$SANDBOX/empty-cwd.out" 2>&1 && {
  echo "FAIL: empty --target-cwd should be rejected"; exit 1; }
grep -q "must not be empty" "$SANDBOX/empty-cwd.out" || {
  echo "FAIL: empty --target-cwd error message missing 'must not be empty'"; exit 1; }
echo "empty --target-cwd rejected PASSED"

# ---------------------------------------------------------------------------
# P (R6): UUIDv7 fallback (Python <3.13 without uuid.uuid7) emits valid
# variant bits. RFC 9562 §5.7 requires the variant nibble (group 4 char 0)
# to be in {8, 9, a, b}. The original fallback drew it from raw entropy,
# producing invalid UUIDs ~75% of the time.
# ---------------------------------------------------------------------------
python3 - <<EOF
import sys, uuid
sys.path.insert(0, "$REPO_ROOT/lib")
import session_convert as sc
saved = uuid.uuid7 if hasattr(uuid, "uuid7") else None
if saved is not None:
    delattr(uuid, "uuid7")
try:
    bad = []
    for _ in range(200):
        u = sc.gen_uuid_v7()
        nibble = u.split("-")[3][0].lower()
        if nibble not in "89ab":
            bad.append(u)
    assert not bad, f"{len(bad)}/200 fallback UUIDs have invalid variant nibble (RFC 9562 §5.7); sample: {bad[:3]}"
finally:
    if saved is not None:
        uuid.uuid7 = saved
print("UUIDv7 fallback variant nibble PASSED")
EOF

# ---------------------------------------------------------------------------
# Q (R7): per-record source timestamps survive conversion. Without
# preservation, every converted record carries wall-clock-at-conversion
# time, losing the actual ordering and historical context that a session
# transcript is supposed to record.
# ---------------------------------------------------------------------------
TQ_UUID="00000000-0000-7000-8000-000000000029"
TQ_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-11-00-$TQ_UUID.jsonl"
cat > "$TQ_PATH" <<EOF
{"timestamp":"2020-06-15T12:00:00.000Z","type":"session_meta","payload":{"id":"$TQ_UUID","timestamp":"2020-06-15T12:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2020-06-15T12:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2020-06-15T12:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"timestamp marker","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2020-06-15T12:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"reply marker"}],"phase":"commentary"}}
EOF

OUT="$SANDBOX/ts.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TQ_UUID" >"$OUT" 2>&1
TQ_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TQ_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TQ_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TQ_NEW_PATH") if l.strip()]
ts_values = [r.get("timestamp", "") for r in records]
preserved = [t for t in ts_values if t.startswith("2020-06-15")]
assert preserved, f"no source timestamp preserved; got {ts_values!r}"
print(f"source timestamps preserved on {len(preserved)} record(s) PASSED")
EOF

# ---------------------------------------------------------------------------
# R (S1): distinct per-emission timestamps. When a single Claude assistant
# record carries text + tool_use, the converted Codex rollout must emit
# multiple records with distinct timestamps (real Codex rollouts always do
# — same-time stamps look anomalous to readers and to anything that orders
# by ts secondarily).
# ---------------------------------------------------------------------------
TR_UUID="00000000-0000-4000-8000-00000000002a"
TR_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TR_UUID.jsonl"
cat > "$TR_PATH" <<'EOF'
{"type":"user","uuid":"u1","parentUuid":null,"sessionId":"00000000-0000-4000-8000-00000000002a","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2025-03-01T08:00:00.000Z","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"do work"}]}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"00000000-0000-4000-8000-00000000002a","cwd":"/tmp/sandbox-project","version":"1.0.0","userType":"external","timestamp":"2025-03-01T08:00:01.000Z","isSidechain":false,"requestId":"req_t","message":{"id":"m1","type":"message","role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"thinking out loud"},{"type":"tool_use","id":"toolu_dist1","name":"Bash","input":{"command":"ls"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":10}}}
EOF

OUT="$SANDBOX/distinct-ts.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$TR_UUID" >"$OUT" 2>&1
TR_NEW_PATH="$(grep '^converted:' "$OUT" | awk -F'-> ' '{print $2}')"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TR_NEW_PATH") if l.strip()]
# Two response_item records derive from the assistant turn (text + tool_use)
# and must carry distinct, monotonic timestamps anchored at the source ts.
ts_2025 = [r["timestamp"] for r in records if r["timestamp"].startswith("2025-03-01T08:00:01")]
assert len(ts_2025) == 2, f"expected 2 records derived from assistant ts; got {ts_2025}"
assert ts_2025[0] != ts_2025[1], f"derived records share timestamp {ts_2025[0]!r}"
assert ts_2025[0] < ts_2025[1], f"derived ts not monotonic: {ts_2025}"
print(f"distinct per-emission timestamps PASSED ({ts_2025[0]} < {ts_2025[1]})")
EOF

# ---------------------------------------------------------------------------
# S (S4): now_iso() fallback when a source record has no `timestamp` field.
# Without the fallback the converted record could carry an empty string for
# timestamp (downstream tools expect ISO-Z shape).
# ---------------------------------------------------------------------------
TS_UUID="00000000-0000-7000-8000-00000000002b"
TS_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-12-00-$TS_UUID.jsonl"
cat > "$TS_PATH" <<EOF
{"timestamp":"2020-06-15T12:00:00.000Z","type":"session_meta","payload":{"id":"$TS_UUID","timestamp":"2020-06-15T12:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"type":"event_msg","payload":{"type":"user_message","message":"no-ts marker","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2020-06-15T12:00:03.000Z","type":"event_msg","payload":{"type":"user_message","message":"with-ts marker","images":[],"local_images":[],"text_elements":[]}}
EOF

OUT="$SANDBOX/no-ts.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TS_UUID" >"$OUT" 2>&1
TS_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TS_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TS_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TS_NEW_PATH") if l.strip()]
texts_to_ts = {}
for r in records:
    msg = r.get("message", {})
    for b in msg.get("content", []):
        if isinstance(b, dict) and b.get("type") == "text":
            texts_to_ts[b["text"]] = r["timestamp"]
assert "no-ts marker" in texts_to_ts, f"no-ts record missing; got {list(texts_to_ts)}"
assert "with-ts marker" in texts_to_ts, f"with-ts record missing; got {list(texts_to_ts)}"
# The with-ts record preserves source year (2020).
assert texts_to_ts["with-ts marker"].startswith("2020-06-15"), \
    f"with-ts source timestamp not preserved: {texts_to_ts['with-ts marker']!r}"
# The no-ts record falls back to a 'now-ish' timestamp — must NOT carry source year.
assert not texts_to_ts["no-ts marker"].startswith("2020-"), \
    f"no-ts record should fall back to now_iso(), got {texts_to_ts['no-ts marker']!r}"
# Sanity: the fallback shape is ISO-Z, not empty.
assert texts_to_ts["no-ts marker"].endswith("Z") and len(texts_to_ts["no-ts marker"]) >= 20, \
    f"no-ts fallback ts malformed: {texts_to_ts['no-ts marker']!r}"
print("now_iso() fallback for missing-timestamp records PASSED")
EOF

# ---------------------------------------------------------------------------
# T (Class A): custom_tool_call carries genuine content (e.g. apply_patch
# input/output strings) that is NOT duplicated in any other record. Empirical
# corpus scan (377 local rollouts, 2026-05-04): 1542 custom_tool_call + 1542
# custom_tool_call_output records exist. Pre-fix the converter dropped them
# silently; this test exercises the fold-to-text path so future schema
# changes do not regress to silent loss.
# ---------------------------------------------------------------------------
TT_UUID="00000000-0000-7000-8000-00000000002c"
TT_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-13-00-$TT_UUID.jsonl"
cat > "$TT_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TT_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Apply the patch","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_CTC01","name":"apply_patch","input":"*** Begin Patch\n*** Update File: foo.txt\n@@\n-old line\n+CTC-PATCH-MARKER-PUMPKIN\n*** End Patch"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_CTC01","output":"CTC-OUTPUT-MARKER-RUTABAGA"}}
EOF

OUT="$SANDBOX/ctc.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TT_UUID" >"$OUT" 2>&1
TT_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TT_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TT_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TT_NEW_PATH") if l.strip()]
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
assert "apply_patch" in joined, f"custom_tool_call name lost; got {joined!r}"
assert "CTC-PATCH-MARKER-PUMPKIN" in joined, f"custom_tool_call input content silently dropped; got {joined!r}"
assert "CTC-OUTPUT-MARKER-RUTABAGA" in joined, f"custom_tool_call_output content silently dropped; got {joined!r}"
# No tool_use blocks (custom_tool_call has no Claude equivalent — must fold).
for r in records:
    if r["type"] != "assistant":
        continue
    for block in r["message"]["content"]:
        assert block.get("type") != "tool_use", "custom_tool_call leaked as tool_use"
print("custom_tool_call/_output fold-to-text PASSED")
EOF

# ---------------------------------------------------------------------------
# U (Class A): web_search_call carries the search query (action.query and
# action.queries) and intent (action.type=search/open_page). Empirical corpus
# scan: 383 web_search_call records. Pre-fix dropped silently; the fold-to-
# text path preserves the model's view of the search.
# ---------------------------------------------------------------------------
TU_UUID="00000000-0000-7000-8000-00000000002d"
TU_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-14-00-$TU_UUID.jsonl"
cat > "$TU_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TU_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Search","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","query":"WSC-MARKER-CHESTNUT","queries":["WSC-MARKER-CHESTNUT"]}}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"open_page","url":"https://docs.example.com/wsc-page"}}}
EOF

OUT="$SANDBOX/wsc.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TU_UUID" >"$OUT" 2>&1
TU_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TU_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TU_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TU_NEW_PATH") if l.strip()]
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
assert "WSC-MARKER-CHESTNUT" in joined, f"web_search_call query silently dropped; got {joined!r}"
assert "wsc-page" in joined, f"web_search_call open_page url silently dropped; got {joined!r}"
print("web_search_call fold-to-text PASSED")
EOF

# ---------------------------------------------------------------------------
# V (Class A): unknown response_item or event_msg payload type emits a
# stderr warning so future Codex schema additions are surfaced rather than
# silently dropped. Documented drops (reasoning, token_count, agent_message
# duplicate, etc.) MUST NOT trigger the warning — only genuinely unknown
# types. This makes the dispatch a known-list contract instead of an
# implicit allowlist with a silent default.
# ---------------------------------------------------------------------------
TV_UUID="00000000-0000-7000-8000-00000000002e"
TV_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-15-00-$TV_UUID.jsonl"
cat > "$TV_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TV_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"hello","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"newly_invented_codex_type_zzz","detail":"future schema"}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"event_msg","payload":{"type":"reasoning","summary":"intentional drop"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"event_msg","payload":{"type":"token_count","input_tokens":10}}
EOF

OUT="$SANDBOX/unk.stdout"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TV_UUID" >"$OUT" 2>"$SANDBOX/unk.stderr"
grep -q "newly_invented_codex_type_zzz" "$SANDBOX/unk.stderr" || {
  echo "FAIL: unknown response_item type was silently dropped (no stderr warning)"
  cat "$SANDBOX/unk.stderr"
  exit 1; }
# Documented drops MUST NOT warn — token_count is intentional.
if grep -qi "token_count" "$SANDBOX/unk.stderr"; then
  echo "FAIL: documented-drop type 'token_count' triggered noisy warning"
  cat "$SANDBOX/unk.stderr"
  exit 1
fi
echo "unknown-record-type warning PASSED (documented drops stay quiet)"

# ---------------------------------------------------------------------------
# W (Class A): agent_message is dropped on cross-vendor — empirical corpus
# scan (60 rollouts, 6164 agent_message records, 2026-05-04 local data):
# 5798/6164 (94%) agent_message text is duplicated in a neighboring
# response_item.message; the remaining 6% are intermediate streaming status
# pings the source model emitted during a turn but never published. Adding
# a handler would duplicate content for the 94% case; dropping is correct.
# This test pins the behavior so a future maintainer doesn't add a handler
# thinking it's missing.
# ---------------------------------------------------------------------------
TW_UUID="00000000-0000-7000-8000-00000000002f"
TW_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-16-00-$TW_UUID.jsonl"
cat > "$TW_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TW_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"AM-MARKER-INTERMEDIATE"}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"event_msg","payload":{"type":"agent_message","message":"AM-MARKER-FINAL"}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"AM-MARKER-FINAL"}],"phase":"commentary"}}
EOF

OUT="$SANDBOX/am.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TW_UUID" >"$OUT" 2>"$SANDBOX/am.stderr"
TW_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TW_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TW_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TW_NEW_PATH") if l.strip()]
texts = [b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict)]
final_count = sum(1 for t in texts if "AM-MARKER-FINAL" in t)
inter_count = sum(1 for t in texts if "AM-MARKER-INTERMEDIATE" in t)
assert final_count == 1, f"final assistant content lost or duplicated: {final_count}; texts={texts}"
assert inter_count == 0, f"intermediate agent_message leaked into output: {inter_count}; texts={texts}"
print("agent_message intentional-drop PASSED (no duplication, final content preserved)")
EOF
# agent_message is documented; must not warn.
if grep -qi "agent_message" "$SANDBOX/am.stderr"; then
  echo "FAIL: documented-drop type 'agent_message' triggered noisy warning"
  cat "$SANDBOX/am.stderr"
  exit 1
fi

# ---------------------------------------------------------------------------
# X (Class B): invalid UTF-8 bytes in source must produce a stderr warning
# and conversion proceeds; the converter must not crash with an unhandled
# UnicodeDecodeError. Pre-fix the open(encoding="utf-8") call would raise
# uncaught when the file contained any non-UTF-8 byte.
# ---------------------------------------------------------------------------
TX_UUID="00000000-0000-7000-8000-000000000030"
TX_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-17-00-$TX_UUID.jsonl"
TX_PATH="$TX_PATH" TX_UUID="$TX_UUID" CWD="$CWD" python3 - <<'PYEOF'
import json
import os
path = os.environ["TX_PATH"]
uid = os.environ["TX_UUID"]
cwd = os.environ["CWD"]
recs = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":uid,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}},
    {"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"X-VALID-MARKER-LIME","images":[],"local_images":[],"text_elements":[]}},
]
with open(path, "wb") as f:
    for r in recs:
        f.write(json.dumps(r).encode("utf-8"))
        f.write(b"\n")
    f.write(b"\xff\xfe\x80garbage-bytes-here\xc3\x28\n")
PYEOF

OUT="$SANDBOX/utf8-bad.stdout"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TX_UUID" >"$OUT" 2>"$SANDBOX/utf8-bad.stderr" || {
    echo "FAIL: converter crashed on invalid UTF-8 bytes"
    cat "$SANDBOX/utf8-bad.stderr"
    exit 1
  }
TX_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TX_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TX_NEW_UUID.jsonl"
grep -q "X-VALID-MARKER-LIME" "$TX_NEW_PATH" || {
  echo "FAIL: valid line lost when source has bad UTF-8 bytes"; exit 1; }
echo "invalid-UTF-8 source warn-and-skip PASSED"

# ---------------------------------------------------------------------------
# Y (Class E): SIGTERM handler is installed and promotes SIGTERM to
# SystemExit, so write_jsonl's BaseException cleanup runs and the .tmp file
# is unlinked. Default SIGTERM handling on POSIX terminates without raising,
# which would leave stale .tmp residue.
# ---------------------------------------------------------------------------
python3 - <<EOF
import os, signal, sys
sys.path.insert(0, "$REPO_ROOT/lib")
import session_convert as sc
sc._install_sigterm_handler()
handler = signal.getsignal(signal.SIGTERM)
assert callable(handler) and handler != signal.SIG_DFL, "SIGTERM handler not installed"
try:
    os.kill(os.getpid(), signal.SIGTERM)
    raise AssertionError("SIGTERM did not raise SystemExit")
except SystemExit as exc:
    assert exc.code == 143, f"unexpected SystemExit code: {exc.code}"
print("SIGTERM handler installs and promotes to SystemExit PASSED")
EOF

# Atomic-write cleanup runs on a mid-write exception (proxy for SIGTERM
# now that it raises SystemExit, which is a BaseException).
python3 - <<EOF
import json, sys, tempfile
sys.path.insert(0, "$REPO_ROOT/lib")
import session_convert as sc
from pathlib import Path

with tempfile.TemporaryDirectory() as td:
    target = Path(td) / "out.jsonl"
    orig_dumps = json.dumps
    calls = {"n": 0}
    def boom(*a, **kw):
        calls["n"] += 1
        if calls["n"] >= 2:
            raise RuntimeError("simulated mid-write failure")
        return orig_dumps(*a, **kw)
    json.dumps = boom
    try:
        try:
            sc.write_jsonl(target, [{"a": 1}, {"a": 2}, {"a": 3}])
        except RuntimeError:
            pass
    finally:
        json.dumps = orig_dumps
    assert not target.exists(), f"final file should not exist after failed write: {target}"
    tmp = target.with_name(target.name + ".tmp")
    assert not tmp.exists(), f"tmp file leaked after failed write: {tmp}"
print("atomic-write cleanup on mid-write exception PASSED")
EOF

# ---------------------------------------------------------------------------
# Z (Class F): encode_claude_project must match Claude's actual lookup
# convention. Reverse-engineered from 64 real Claude sessions in
# ~/.claude/projects on macOS (2026-05-04 local data): empirical fit was
# 63/64 with the rule "realpath then replace [^A-Za-z0-9-] with -".
# Pre-fix the encoder did "/" → "-" only; symlinked paths (/tmp →
# /private/tmp) wrote under -tmp-foo while claude --resume looked under
# -private-tmp-foo, leaving converted sessions invisible.
# ---------------------------------------------------------------------------
python3 - <<EOF
import sys, os, re
sys.path.insert(0, "$REPO_ROOT/lib")
import session_convert as sc

# Underscores → dashes (real session example: clone_dir → clone-dir).
assert sc.encode_claude_project("/Users/test/clone_dir") == "-Users-test-clone-dir", \
    "underscore not replaced"
# Dots → dashes (real session example: ~/.claude → -Users-spson--claude).
assert sc.encode_claude_project("/Users/test/.claude") == "-Users-test--claude", \
    "dot not replaced"
# Spaces → dashes (real session example: Application Support).
assert sc.encode_claude_project("/Library/Application Support/x") == "-Library-Application-Support-x", \
    "space not replaced"
# realpath is applied: on macOS /tmp is a symlink to /private/tmp; the
# encoder must follow it so the result matches what claude --resume scans.
if os.path.realpath("/tmp") == "/private/tmp":
    assert sc.encode_claude_project("/tmp/foo-bar") == "-private-tmp-foo-bar", \
        "realpath /tmp → /private/tmp not chased"
print("encode_claude_project matches Claude's lookup convention PASSED")
EOF

# ---------------------------------------------------------------------------
# AA (Class B): emit() must not crash with UnicodeEncodeError when stdout
# is ASCII (PYTHONUTF8=0 LC_ALL=C) and the source/target paths contain
# non-ASCII characters. Pre-fix the bare sys.stdout.write call inherited
# the locale encoding and raised UnicodeEncodeError mid-conversion.
# ---------------------------------------------------------------------------
TAA_HOME="$SANDBOX/utf8-home/코덱스-home"
mkdir -p "$TAA_HOME/sessions/2026/05/04"
TAA_UUID="00000000-0000-7000-8000-aaaaaaaaaaaa"
cat > "$TAA_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-$TAA_UUID.jsonl" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TAA_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"/tmp/utf8-test","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi","images":[],"local_images":[],"text_elements":[]}}
EOF

CODEX_HOME="$TAA_HOME" CLAUDE_HOME="$SANDBOX/utf8-claude" \
  PYTHONUTF8=0 LC_ALL=C \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TAA_UUID" >"$SANDBOX/utf8-emit.stdout" 2>"$SANDBOX/utf8-emit.stderr" || {
    echo "FAIL: emit() crashed under PYTHONUTF8=0 LC_ALL=C with non-ASCII source path"
    cat "$SANDBOX/utf8-emit.stderr"
    exit 1
  }
grep -q '^new session UUID:' "$SANDBOX/utf8-emit.stdout" || {
  echo "FAIL: emit() output missing the expected 'new session UUID:' line"
  cat "$SANDBOX/utf8-emit.stdout"
  exit 1; }
echo "emit() under C locale with non-ASCII paths PASSED"

# ---------------------------------------------------------------------------
# BB (review #5 Kimi): _bump_ts_ms must handle pathological timestamp shapes
# without producing malformed timestamps or losing precision. Pre-fix:
# multi-dot inputs like '...00.123.456Z' produced '...00.123.457Z' (still
# multi-dot, unparseable as ISO), and short fractions like '...00.12Z' were
# misread as 12ms instead of 120ms (3-digit ms).
# ---------------------------------------------------------------------------
python3 - <<EOF
import sys
sys.path.insert(0, "$REPO_ROOT/lib")
import session_convert as sc

cases = [
    ("2026-05-04T00:00:00.000Z",     "2026-05-04T00:00:00.001Z"),
    ("2026-05-04T00:00:00Z",         "2026-05-04T00:00:00.001Z"),
    ("2026-05-04T00:00:00.999Z",     "2026-05-04T00:00:00.999Z"),
    # Multi-dot: returns ts unchanged (does not produce '...00.123.457Z').
    ("2026-05-04T00:00:00.123.456Z", "2026-05-04T00:00:00.123.456Z"),
    # 2-digit fraction means 120ms not 12ms — pad to 3-digit before bump.
    ("2026-05-04T00:00:00.12Z",      "2026-05-04T00:00:00.121Z"),
    # 1-digit fraction means 100ms.
    ("2026-05-04T00:00:00.1Z",       "2026-05-04T00:00:00.101Z"),
    # Microsecond fraction: truncate to 3 digits before bump.
    ("2026-05-04T00:00:00.123456Z",  "2026-05-04T00:00:00.124Z"),
]
for inp, want in cases:
    got = sc._bump_ts_ms(inp, 1)
    assert got == want, f"_bump_ts_ms({inp!r}) = {got!r}, expected {want!r}"
print("_bump_ts_ms edge cases (multi-dot, short fraction, microseconds) PASSED")
EOF

# ---------------------------------------------------------------------------
# CC (review #6): custom_tool_call_output that has no matching custom_tool_call
# in the source (e.g. the call was abandoned in a turn_aborted) is folded as
# an "Orphan tool result" rather than a normal companion fold, so a reader of
# the converted session can tell linkage was broken.
# ---------------------------------------------------------------------------
TCC_UUID="00000000-0000-7000-8000-000000000032"
TCC_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-19-00-$TCC_UUID.jsonl"
cat > "$TCC_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TCC_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"call abandoned","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_NEVER_SEEN","output":"ORPHAN-OUTPUT-MARKER-PERIWINKLE"}}
EOF

OUT="$SANDBOX/orphan-ctc.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TCC_UUID" >"$OUT" 2>&1
TCC_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TCC_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TCC_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TCC_NEW_PATH") if l.strip()]
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
assert "ORPHAN-OUTPUT-MARKER-PERIWINKLE" in joined, f"orphan output content silently dropped; got {joined!r}"
# Exactly one orphan-fold and zero companion-folds: counts assert directly so
# a maintainer reading the test sees the invariant without parsing replace gymnastics.
assert joined.count("[Orphan tool result:") == 1, f"expected one orphan-fold; got {joined!r}"
assert joined.count("[Tool result:") == 0, f"orphan output mis-classified as companion; got {joined!r}"
print("orphan custom_tool_call_output flagged as orphan PASSED")
EOF

# ---------------------------------------------------------------------------
# DD (review #7): empty call_id must always orphan-flag the output, never
# accidentally match another empty-call_id record. Real Codex always emits
# proper `call_*` ids; this test pins the contract for malformed sources.
# Pre-fix: an empty-call_id call AND an empty-call_id output would both store
# `""` in custom_tool_call_ids, the membership check would succeed, and the
# output got the COMPANION fold even though the linkage is meaningless.
# ---------------------------------------------------------------------------
TDD_UUID="00000000-0000-7000-8000-000000000033"
TDD_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-20-00-$TDD_UUID.jsonl"
cat > "$TDD_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TDD_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"empty-id corruption","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"","name":"corrupt_call","input":"EMPTYID-CALL-INPUT-MARMALADE"}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"","output":"EMPTYID-OUTPUT-MARKER-CILANTRO"}}
EOF

OUT="$SANDBOX/empty-id.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TDD_UUID" >"$OUT" 2>&1
TDD_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TDD_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TDD_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TDD_NEW_PATH") if l.strip()]
joined = "".join(b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict))
# The call's input still surfaces (preserved as text — distinct content).
assert "EMPTYID-CALL-INPUT-MARMALADE" in joined, f"empty-id call input lost; got {joined!r}"
# The output also surfaces but as orphan, not companion: empty IDs do NOT
# count as a linkage match.
assert "EMPTYID-OUTPUT-MARKER-CILANTRO" in joined, f"empty-id output lost; got {joined!r}"
assert joined.count("[Orphan tool result:") == 1, f"empty-id output should orphan-flag; got {joined!r}"
assert joined.count("[Tool result:") == 0, f"empty-id output incorrectly classified as companion; got {joined!r}"
print("empty call_id always orphans (no false linkage) PASSED")
EOF

# ---------------------------------------------------------------------------
# EE (review #8 GLM BUG): Claude user records with `content` as a plain string
# (~17% of real local user records, 2026-05-04 corpus scan) must survive
# claude-to-codex conversion. Pre-fix: the input loop's
# `if not isinstance(content, list): continue` silently dropped these, losing
# user prompts in any session that mixed string-form and list-form turns.
# Fix normalizes a string content to a single text block before the
# isinstance check.
# ---------------------------------------------------------------------------
EE_SRC_UUID="00000000-0000-4000-8000-deadbeef00ee"
EE_SRC="$CLAUDE_HOME/projects/$ENCODED_CWD/$EE_SRC_UUID.jsonl"
python3 - "$EE_SRC" "$EE_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"type":"user","uuid":"u1","parentUuid":None,"sessionId":uuid_,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:00.000Z","isSidechain":False,
     "message":{"role":"user","content":"STRING-FORM-USER-PROMPT-CARDAMOM"}},
    {"type":"user","uuid":"u2","parentUuid":"u1","sessionId":uuid_,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:01.000Z","isSidechain":False,
     "message":{"role":"user","content":[{"type":"text","text":"LIST-FORM-USER-PROMPT-VANILLA"}]}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
EE_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$EE_SRC_UUID")
EE_NEW_PATH=$(echo "$EE_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
python3 - "$EE_NEW_PATH" <<'EOF'
import json, sys
records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
user_msgs = [r["payload"]["message"] for r in records
             if r.get("type") == "event_msg"
             and r.get("payload", {}).get("type") == "user_message"]
joined = "\n".join(user_msgs)
assert "STRING-FORM-USER-PROMPT-CARDAMOM" in joined, \
    f"string-content user record was DROPPED; got {joined!r}"
assert "LIST-FORM-USER-PROMPT-VANILLA" in joined, \
    f"list-content user record regression; got {joined!r}"
print("string-content Claude user records survive claude-to-codex PASSED")
EOF

# ---------------------------------------------------------------------------
# FF (review #8 DeepSeek/Kimi/GLM): event_msg payload types observed in real
# local rollouts but missing from _CODEX_EVENT_MSG_DOCUMENTED_DROP must
# either drop silently (DOCUMENTED) or warn loudly (UNKNOWN). The 2026-05-04
# corpus scan turned up `dynamic_tool_call_response`, `thread_rolled_back`,
# and `item_completed`. All three must be silent (added to DOCUMENTED_DROP);
# a fabricated future type must still warn.
# ---------------------------------------------------------------------------
FF_SRC_UUID="019dee99-1234-7000-8000-deadbeef00ff"
FF_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-${FF_SRC_UUID}.jsonl"
python3 - "$FF_SRC" "$FF_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":uuid_,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"codex","cli_version":"0.0.0-test","source":"cli","model_provider":"openai","base_instructions":{"text":"x"}}},
    {"timestamp":"2026-05-04T00:00:01.000Z","type":"event_msg","payload":{"type":"dynamic_tool_call_response","call_id":"call_X","tool":"x","content_items":[]}},
    {"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}},
    {"timestamp":"2026-05-04T00:00:03.000Z","type":"event_msg","payload":{"type":"item_completed"}},
    {"timestamp":"2026-05-04T00:00:04.000Z","type":"event_msg","payload":{"type":"future_unknown_drift_QQQ"}},
    {"timestamp":"2026-05-04T00:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}],"phase":"commentary"}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
FF_STDERR_FILE="$SANDBOX/ff_stderr.txt"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$FF_SRC_UUID" \
    >/dev/null 2>"$FF_STDERR_FILE" || true
python3 - "$FF_STDERR_FILE" <<'EOF'
import sys
err = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
# Documented drops must NOT warn.
for kind in ("dynamic_tool_call_response", "thread_rolled_back", "item_completed"):
    assert kind not in err, f"{kind} should be silent now, but warning fired:\n{err}"
# A genuinely unknown type MUST warn — schema-drift surfacing is the
# load-bearing contract of _warn_unknown.
assert "future_unknown_drift_QQQ" in err, \
    f"unknown event_msg type was suppressed silently; stderr was:\n{err!r}"
print("documented-drop additions silent / unknown still warns PASSED")
EOF

# ---------------------------------------------------------------------------
# GG (review #8 Gemini RISK): nested task_started + turn_aborted. The
# response_items between the INNERMOST task_started and a turn_aborted must
# be discarded; outer-task content must survive. Pre-fix: scalar
# pending_start was overwritten by the inner task_started, so a later
# outer-level abort would do nothing and leak abandoned content (or, if the
# inner abort fired without a complete, the outer task_started index was
# already lost).
# ---------------------------------------------------------------------------
GG_SRC_UUID="019dee99-2234-7000-8000-deadbeef0099"
GG_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-${GG_SRC_UUID}.jsonl"
python3 - "$GG_SRC" "$GG_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
def msg(t, ts):
    return {"timestamp":ts,"type":"response_item",
            "payload":{"type":"message","role":"assistant",
                       "content":[{"type":"output_text","text":t}],"phase":"commentary"}}
def life(kind, ts):
    return {"timestamp":ts,"type":"event_msg","payload":{"type":kind}}
records = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":uuid_,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"codex","cli_version":"0.0.0-test","source":"cli","model_provider":"openai","base_instructions":{"text":"x"}}},
    msg("OUTER-BEFORE", "2026-05-04T00:00:01.000Z"),
    life("task_started",  "2026-05-04T00:00:02.000Z"),  # outer
    msg("OUTER-DURING-PRE-INNER", "2026-05-04T00:00:03.000Z"),
    life("task_started",  "2026-05-04T00:00:04.000Z"),  # inner
    msg("INNER-DOOMED-CONTENT", "2026-05-04T00:00:05.000Z"),
    life("turn_aborted",  "2026-05-04T00:00:06.000Z"),  # aborts inner only
    msg("OUTER-DURING-POST-INNER", "2026-05-04T00:00:07.000Z"),
    life("task_complete", "2026-05-04T00:00:08.000Z"),  # outer completes normally
    msg("OUTER-AFTER", "2026-05-04T00:00:09.000Z"),
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
GG_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$GG_SRC_UUID")
GG_NEW_PATH=$(echo "$GG_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
python3 - "$GG_NEW_PATH" <<'EOF'
import json, sys
records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
joined = "\n".join(
    b.get("text","")
    for r in records
    for b in r.get("message",{}).get("content",[])
    if isinstance(b, dict)
)
# Inner-task content was aborted: must be gone.
assert "INNER-DOOMED-CONTENT" not in joined, \
    f"inner-aborted content leaked into converted session: {joined!r}"
# All outer-task content (before, during pre/post inner, after) survives —
# the outer task_complete'd normally.
for keep in ("OUTER-BEFORE", "OUTER-DURING-PRE-INNER",
             "OUTER-DURING-POST-INNER", "OUTER-AFTER"):
    assert keep in joined, f"outer-task content {keep!r} lost: {joined!r}"
print("nested task_started + inner turn_aborted preserves outer content PASSED")
EOF

# ---------------------------------------------------------------------------
# HH (review #8 DeepSeek RISK): direct python3 invocation with empty
# --target-cwd must be rejected at the Python boundary (the bash wrapper
# already rejects empty --target-cwd; this closes the parallel hole for
# library callers who skip the wrapper).
# ---------------------------------------------------------------------------
HH_SRC_UUID="019dee99-3234-7000-8000-deadbeef0088"
HH_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-${HH_SRC_UUID}.jsonl"
python3 - "$HH_SRC" "$HH_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":uuid_,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"codex","cli_version":"0.0.0-test","source":"cli","model_provider":"openai","base_instructions":{"text":"x"}}},
    {"timestamp":"2026-05-04T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}],"phase":"commentary"}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
set +e
HH_STDERR=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$HH_SRC_UUID" --target-cwd "" 2>&1 >/dev/null)
HH_RC=$?
set -e
case "$HH_STDERR" in
    *"--target-cwd must not be an empty string"*)
        [ "$HH_RC" -ne 0 ] || { echo "FAIL: empty --target-cwd accepted by Python entry point"; exit 1; }
        echo "Python-side empty --target-cwd rejection PASSED"
        ;;
    *)
        echo "FAIL: expected empty-target-cwd ValueError, got rc=$HH_RC stderr=$HH_STDERR"
        exit 1
        ;;
esac


echo "all converter sandbox tests passed"
