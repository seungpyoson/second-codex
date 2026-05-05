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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
if grep -q "^note:" "$SANDBOX/ct.out"; then
  echo "FAIL: explicit --target-cwd should not emit cwd mismatch note"
  cat "$SANDBOX/ct.out"
  exit 1
fi

# Without --target-cwd, source-cwd preservation remains the default. When the
# invoking shell is in a different cwd, print a discoverability hint so the
# bare `claude --resume` line is not a silent current-project cliff.
CH_UUID="00000000-0000-7000-8000-000000000040"
CH_SOURCE_CWD="$SANDBOX/source project"
CH_INVOKE_CWD="$SANDBOX/invoke project"
CH_INVOKE_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$CH_INVOKE_CWD")"
CH_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-04-01-$CH_UUID.jsonl"
mkdir -p "$CH_SOURCE_CWD" "$CH_INVOKE_CWD"
cat > "$CH_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CH_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CH_SOURCE_CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"placeholder","images":[],"local_images":[],"text_elements":[]}}
EOF
(
  cd "$CH_INVOKE_CWD"
  CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    "$REPO_ROOT/second-codex" handoff-to-claude "$CH_UUID" >"$SANDBOX/ch.stdout" 2>"$SANDBOX/ch.stderr"
)
grep -q "^resume with: claude --resume" "$SANDBOX/ch.stdout" || {
  echo "FAIL: cwd mismatch stdout lost resume command"; cat "$SANDBOX/ch.stdout"; exit 1; }
if grep -q "^note:" "$SANDBOX/ch.stdout"; then
  echo "FAIL: cwd mismatch notes should be on stderr, not stdout"
  cat "$SANDBOX/ch.stdout"
  exit 1
fi
grep -q -- "--target-cwd" "$SANDBOX/ch.stderr" || {
  echo "FAIL: cwd mismatch stderr did not mention --target-cwd"; cat "$SANDBOX/ch.stderr"; exit 1; }
grep -q "$CH_SOURCE_CWD" "$SANDBOX/ch.stderr" || {
  echo "FAIL: cwd mismatch stderr did not mention source cwd"; cat "$SANDBOX/ch.stderr"; exit 1; }
grep -q "$CH_INVOKE_REAL" "$SANDBOX/ch.stderr" || {
  echo "FAIL: cwd mismatch stderr did not mention invoking cwd"; cat "$SANDBOX/ch.stderr"; exit 1; }

CM_UUID="00000000-0000-7000-8000-000000000041"
CM_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-04-02-$CM_UUID.jsonl"
cat > "$CM_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CM_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CH_INVOKE_REAL","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"placeholder","images":[],"local_images":[],"text_elements":[]}}
EOF
(
  cd "$CH_INVOKE_CWD"
  CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    "$REPO_ROOT/second-codex" handoff-to-claude "$CM_UUID" >"$SANDBOX/cm.out" 2>&1
)
if grep -q "^note: .*--target-cwd" "$SANDBOX/cm.out"; then
  echo "FAIL: cwd match output should not print --target-cwd mismatch hint"
  cat "$SANDBOX/cm.out"
  exit 1
fi

CH_TILDE_UUID="00000000-0000-7000-8000-000000000042"
CH_TILDE_HOME="$SANDBOX/tilde-home"
CH_TILDE_SOURCE="~/source project"
CH_TILDE_EXPANDED="$CH_TILDE_HOME/source project"
CH_TILDE_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-04-03-$CH_TILDE_UUID.jsonl"
mkdir -p "$CH_TILDE_EXPANDED"
cat > "$CH_TILDE_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CH_TILDE_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CH_TILDE_SOURCE","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"placeholder","images":[],"local_images":[],"text_elements":[]}}
EOF
(
  cd "$CH_INVOKE_CWD"
  HOME="$CH_TILDE_HOME" CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    "$REPO_ROOT/second-codex" handoff-to-claude "$CH_TILDE_UUID" >"$SANDBOX/ch-tilde.stdout" 2>"$SANDBOX/ch-tilde.stderr"
)
grep -Fq "$CH_TILDE_EXPANDED" "$SANDBOX/ch-tilde.stderr" || {
  echo "FAIL: tilde source cwd should emit cd hint with expanded path"
  cat "$SANDBOX/ch-tilde.stderr"
  exit 1
}
grep -Fq "&& claude --resume" "$SANDBOX/ch-tilde.stderr" || {
  echo "FAIL: tilde source cwd should emit claude resume command in cd hint"
  cat "$SANDBOX/ch-tilde.stderr"
  exit 1
}

CH_MISSING_UUID="00000000-0000-7000-8000-000000000043"
CH_MISSING_SOURCE="$SANDBOX/missing-source-project"
CH_MISSING_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-04-04-$CH_MISSING_UUID.jsonl"
cat > "$CH_MISSING_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CH_MISSING_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CH_MISSING_SOURCE","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"placeholder","images":[],"local_images":[],"text_elements":[]}}
EOF
(
  cd "$CH_INVOKE_CWD"
  CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    "$REPO_ROOT/second-codex" handoff-to-claude "$CH_MISSING_UUID" >"$SANDBOX/ch-missing.stdout" 2>"$SANDBOX/ch-missing.stderr"
)
grep -q -- "--target-cwd" "$SANDBOX/ch-missing.stderr" || {
  echo "FAIL: missing source cwd should still emit generic --target-cwd hint"
  cat "$SANDBOX/ch-missing.stderr"
  exit 1
}
if grep -Fq "&& claude --resume" "$SANDBOX/ch-missing.stderr"; then
  echo "FAIL: missing source cwd should not emit cd resume hint"
  cat "$SANDBOX/ch-missing.stderr"
  exit 1
fi

CH_NO_CWD_UUID="00000000-0000-7000-8000-000000000044"
CH_NO_CWD_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-04-05-$CH_NO_CWD_UUID.jsonl"
CH_INVOKE_ENCODED="$(encode_claude_dir "$CH_INVOKE_REAL")"
cat > "$CH_NO_CWD_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$CH_NO_CWD_UUID","timestamp":"2026-05-04T00:00:00.000Z","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"placeholder","images":[],"local_images":[],"text_elements":[]}}
EOF
(
  cd "$CH_INVOKE_CWD"
  CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    "$REPO_ROOT/second-codex" handoff-to-claude "$CH_NO_CWD_UUID" >"$SANDBOX/ch-no-cwd.stdout" 2>"$SANDBOX/ch-no-cwd.stderr"
)
CH_NO_CWD_PRODUCED="$(grep '^converted:' "$SANDBOX/ch-no-cwd.stdout" | awk -F'-> ' '{print $2}')"
case "$CH_NO_CWD_PRODUCED" in
    *"$CH_INVOKE_ENCODED"*) : ;;
    *) echo "FAIL: no-source-cwd fallback did not use invoking cwd: $CH_NO_CWD_PRODUCED"; exit 1 ;;
esac
if grep -q "^note:" "$SANDBOX/ch-no-cwd.stderr"; then
  echo "FAIL: no-source-cwd fallback should not emit mismatch notes"
  cat "$SANDBOX/ch-no-cwd.stderr"
  exit 1
fi
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"unicode marker 🍊 漢字 ✅","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"echo back: 🍊 漢字 ✅"}],"phase":"commentary"}}
EOF

OUT="$SANDBOX/unicode.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TH_UUID" >"$OUT" 2>&1
TH_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TH_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TH_NEW_UUID.jsonl"

# Bytes on disk must be the unescaped UTF-8, not \uXXXX escape sequences.
# Pattern is one literal backslash + 'u' + 4 hex digits to match JSON's
# \uXXXX escape form in the raw file bytes. The earlier '\\\\u' form was
# four backslashes which after BRE collapse matched '\\u' (two
# backslashes + u) — a double-escaped form that json.dumps never emits,
# so the assertion was vacuously failing to fire even when escapes leaked.
if grep -q '\\u[0-9a-fA-F]\{4\}' "$TH_NEW_PATH"; then
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
if [ "$(grep -c "warning: skipping malformed JSON line" "$SANDBOX/malformed.stderr")" -ne 1 ]; then
    echo "FAIL: malformed JSON warning emitted more than once"
    cat "$SANDBOX/malformed.stderr"
    exit 1
fi
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
# Whitespace-only must also be rejected by the bash wrapper (round-10
# follow-up: extends scenario O to mirror the wrapper guard upgrade from
# `-z` to `[[ =~ ^[[:space:]]*$ ]]`).
"$REPO_ROOT/second-codex" handoff-to-claude "$CODEX_SRC_UUID" --target-cwd $'  \t  ' >"$SANDBOX/whitespace-cwd.out" 2>&1 && {
  echo "FAIL: whitespace-only --target-cwd should be rejected by wrapper"; exit 1; }
grep -q "must not be empty or whitespace-only" "$SANDBOX/whitespace-cwd.out" || {
  echo "FAIL: whitespace-only --target-cwd wrapper error missing expected message; got $(cat "$SANDBOX/whitespace-cwd.out")"; exit 1; }
# Unicode whitespace (NBSP U+00A0, encoded as the raw UTF-8 bytes \xc2\xa0
# so this works on bash 3.2 too) must also be rejected by the wrapper.
# Round-11 follow-up: closes the cosmetic divergence the round-10 panel
# flagged — bash [[:space:]] only matches ASCII, but the wrapper now
# shells out to python3 str.strip() so both boundaries reject the same
# input set.
"$REPO_ROOT/second-codex" handoff-to-claude "$CODEX_SRC_UUID" --target-cwd $'\xc2\xa0' >"$SANDBOX/nbsp-cwd.out" 2>&1 && {
  echo "FAIL: NBSP --target-cwd should be rejected by wrapper"; exit 1; }
grep -q "must not be empty or whitespace-only" "$SANDBOX/nbsp-cwd.out" || {
  echo "FAIL: NBSP --target-cwd wrapper error missing expected message; got $(cat "$SANDBOX/nbsp-cwd.out")"; exit 1; }
echo "empty + ASCII whitespace + Unicode NBSP --target-cwd rejected by wrapper PASSED"

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
{"timestamp":"2020-06-15T12:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
# V (Issue #10): response_item.message is role-dispatched, not a single
# assistant-only shape. Assistant messages are already preserved above; user
# messages are the canonical prompt body in modern Codex rollouts, while the
# adjacent event_msg.user_message is a duplicate compatibility echo. Developer
# messages are runtime policy/environment context and are intentionally not
# portable across vendors, but they must be a documented quiet drop rather than
# an "unknown message" warning.
# ---------------------------------------------------------------------------
TV_UUID="00000000-0000-7000-8000-00000000002e"
TV_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-15-00-$TV_UUID.jsonl"
cat > "$TV_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TV_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"DEV-RUNTIME-CONTEXT-DO-NOT-PORT"},{"type":"input_image","image_url":"data:image/png;base64,BBBB"}]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"UNIQUE-USER-MARKER-LIME"}]}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"DUPLICATE-USER-MARKER-PEAR"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}}
{"timestamp":"2026-05-04T00:00:05.000Z","type":"event_msg","payload":{"type":"user_message","message":"DUPLICATE-USER-MARKER-PEAR","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:06.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ASSISTANT-MARKER-PLUM"}],"phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:07.000Z","type":"event_msg","payload":{"type":"user_message","message":"REVERSE-USER-MARKER-MANGO","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:08.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"REVERSE-USER-MARKER-MANGO"}]}}
{"timestamp":"2026-05-04T00:00:09.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"INTERVENING-USER-MARKER-GRAPE"}]}}
{"timestamp":"2026-05-04T00:00:10.000Z","type":"event_msg","payload":{"type":"token_count","input_tokens":10}}
{"timestamp":"2026-05-04T00:00:11.000Z","type":"event_msg","payload":{"type":"user_message","message":"INTERVENING-USER-MARKER-GRAPE","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:12.000Z","type":"response_item","payload":{"type":"message","role":"user","content":"STRING-USER-MARKER-FIG"}}
{"timestamp":"2026-05-04T00:00:13.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"STRING-ASSISTANT-MARKER-KIWI","phase":"commentary"}}
{"timestamp":"2026-05-04T00:00:14.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"MULTI-"},{"type":"input_text","text":"BLOCK-USER-MARKER-APRICOT"}]}}
{"timestamp":"2026-05-04T00:00:15.000Z","type":"event_msg","payload":{"type":"user_message","message":"MULTI-BLOCK-USER-MARKER-APRICOT","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:16.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,CCCC"}]}}
{"timestamp":"2026-05-04T00:00:17.000Z","type":"response_item","payload":{"type":"message","role":"orchestrator","content":[{"type":"input_text","text":"UNKNOWN-ROLE-MARKER-DO-NOT-PORT"}]}}
{"timestamp":"2026-05-04T00:00:18.000Z","type":"response_item","payload":{"type":"message","role":{"name":"future-role"},"content":[{"type":"input_text","text":"NONSTRING-ROLE-MARKER-DO-NOT-PORT"}]}}
{"timestamp":"2026-05-04T00:00:19.000Z","type":"response_item","payload":{"type":"message","role":null,"content":[{"type":"input_text","text":"NULL-ROLE-MARKER-DO-NOT-PORT"}]}}
{"timestamp":"2026-05-04T00:00:20.000Z","type":"response_item","payload":{"type":"message","role":"user","content":{"type":"input_text","text":"MALFORMED-USER-CONTENT-DO-NOT-PORT"}}}
{"timestamp":"2026-05-04T00:00:21.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":{"type":"output_text","text":"MALFORMED-ASSISTANT-CONTENT-DO-NOT-PORT"}}}
{"timestamp":"2026-05-04T00:00:22.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":{"nested":"MALFORMED-USER-TEXT-DO-NOT-PORT"}}]}}
{"timestamp":"2026-05-04T00:00:23.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":{"nested":"MALFORMED-ASSISTANT-TEXT-DO-NOT-PORT"}}]}}
{"timestamp":"2026-05-04T00:00:24.000Z","type":"event_msg","payload":{"type":"user_message","message":{"nested":"MALFORMED-EVENT-MESSAGE-DO-NOT-PORT"},"images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:25.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"input_text","text":"ASSISTANT-INPUT-TEXT-COMPAT-MARKER-QUINCE"}],"phase":"commentary"}}
EOF

OUT="$SANDBOX/response-item-message.stdout"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TV_UUID" >"$OUT" 2>"$SANDBOX/response-item-message.stderr"
TV_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TV_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TV_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TV_NEW_PATH") if l.strip()]
texts = [b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict)]
joined = "\n".join(texts)
assert "UNIQUE-USER-MARKER-LIME" in joined, f"unique response_item user message was lost: {texts}"
assert sum(1 for t in texts if "DUPLICATE-USER-MARKER-PEAR" in t) == 1, f"duplicate user message was not de-duplicated: {texts}"
assert sum(1 for t in texts if "REVERSE-USER-MARKER-MANGO" in t) == 1, f"reverse-ordered duplicate user message leaked: {texts}"
assert sum(1 for t in texts if "INTERVENING-USER-MARKER-GRAPE" in t) == 1, f"intervening-record duplicate user message leaked: {texts}"
assert sum(1 for t in texts if "MULTI-" in t or "BLOCK-USER-MARKER-APRICOT" in t) == 2, f"multi-block user message was lost or collapsed unexpectedly: {texts}"
assert sum(1 for t in texts if "image attachment omitted" in t) == 2, f"image omission marker missing or duplicated: {texts}"
assert "ASSISTANT-MARKER-PLUM" in joined, f"assistant response_item.message was lost: {texts}"
assert "STRING-USER-MARKER-FIG" in joined, f"string-form response_item user message was lost: {texts}"
assert "STRING-ASSISTANT-MARKER-KIWI" in joined, f"string-form response_item assistant message was lost: {texts}"
assert "DEV-RUNTIME-CONTEXT-DO-NOT-PORT" not in joined, f"developer runtime context leaked into target session: {texts}"
assert "UNKNOWN-ROLE-MARKER-DO-NOT-PORT" not in joined, f"unknown role leaked into target session: {texts}"
assert "NONSTRING-ROLE-MARKER-DO-NOT-PORT" not in joined, f"non-string role leaked into target session: {texts}"
assert "NULL-ROLE-MARKER-DO-NOT-PORT" not in joined, f"null role leaked into target session: {texts}"
assert "MALFORMED-USER-CONTENT-DO-NOT-PORT" not in joined, f"malformed user content leaked into target session: {texts}"
assert "MALFORMED-ASSISTANT-CONTENT-DO-NOT-PORT" not in joined, f"malformed assistant content leaked into target session: {texts}"
assert "MALFORMED-USER-TEXT-DO-NOT-PORT" not in joined, f"malformed user block text leaked into target session: {texts}"
assert "MALFORMED-ASSISTANT-TEXT-DO-NOT-PORT" not in joined, f"malformed assistant block text leaked into target session: {texts}"
assert "MALFORMED-EVENT-MESSAGE-DO-NOT-PORT" not in joined, f"malformed event message leaked into target session: {texts}"
assert "ASSISTANT-INPUT-TEXT-COMPAT-MARKER-QUINCE" in joined, f"assistant input_text compatibility text was lost: {texts}"
print("response_item.message role dispatch PASSED")
EOF

if grep -q "unhandled response_item.payload type 'message'" "$SANDBOX/response-item-message.stderr"; then
  echo "FAIL: known response_item.message role shape still warns as unknown"
  cat "$SANDBOX/response-item-message.stderr"
  exit 1
fi
if grep -q "response_item.message.role type 'developer'" "$SANDBOX/response-item-message.stderr"; then
  echo "FAIL: documented developer message role triggered noisy warning"
  cat "$SANDBOX/response-item-message.stderr"
  exit 1
fi
grep -q "response_item.message.role type 'orchestrator'" "$SANDBOX/response-item-message.stderr" || {
  echo "FAIL: unknown response_item.message role did not warn"
  cat "$SANDBOX/response-item-message.stderr"
  exit 1
}
grep -q "response_item.message.role type '<non-string:dict>'" "$SANDBOX/response-item-message.stderr" || {
  echo "FAIL: non-string response_item.message role did not warn"
  cat "$SANDBOX/response-item-message.stderr"
  exit 1
}
grep -q "response_item.message.role type '<missing>'" "$SANDBOX/response-item-message.stderr" || {
  echo "FAIL: missing/null response_item.message role did not warn"
  cat "$SANDBOX/response-item-message.stderr"
  exit 1
}

# ---------------------------------------------------------------------------
# V (Class A): unknown response_item or event_msg payload type emits a
# stderr warning so future Codex schema additions are surfaced rather than
# silently dropped. Documented drops (reasoning, token_count, agent_message
# duplicate, etc.) MUST NOT trigger the warning — only genuinely unknown
# types. This makes the dispatch a known-list contract instead of an
# implicit allowlist with a silent default.
# ---------------------------------------------------------------------------
TV_UUID="00000000-0000-7000-8000-00000000003e"
TV_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-15-01-$TV_UUID.jsonl"
cat > "$TV_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TV_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
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
# DE (DeepSeek P2): mapped function_call with empty call_id follows the same
# malformed-source contract as custom_tool_call: empty IDs are never valid
# linkage keys. The call folds to text instead of creating an unmatched
# Claude tool_use, and the output is explicitly orphan-marked.
# ---------------------------------------------------------------------------
TDE_UUID="00000000-0000-7000-8000-000000000034"
TDE_PATH="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-20-01-$TDE_UUID.jsonl"
cat > "$TDE_PATH" <<EOF
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"$TDE_UUID","timestamp":"2026-05-04T00:00:00.000Z","cwd":"$CWD","originator":"test","cli_version":"0","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex.\n"}}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":"$CWD","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"empty mapped id corruption","images":[],"local_images":[],"text_elements":[]}}
{"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"function_call","call_id":"","name":"exec_command","arguments":"{\"cmd\":\"EMPTYID-MAPPED-CALL-MARKER-TAMARIND\"}"}}
{"timestamp":"2026-05-04T00:00:04.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"","output":"EMPTYID-MAPPED-OUTPUT-MARKER-SAFFRON"}}
EOF

OUT="$SANDBOX/empty-mapped-id.out"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
  python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$TDE_UUID" >"$OUT" 2>&1
TDE_NEW_UUID="$(grep '^new session UUID:' "$OUT" | awk '{print $NF}')"
TDE_NEW_PATH="$CLAUDE_HOME/projects/$ENCODED_CWD/$TDE_NEW_UUID.jsonl"

python3 - <<EOF
import json
records = [json.loads(l) for l in open("$TDE_NEW_PATH") if l.strip()]
texts = [b.get("text", "") for r in records for b in r.get("message", {}).get("content", []) if isinstance(b, dict)]
joined = "".join(texts)
assert "EMPTYID-MAPPED-CALL-MARKER-TAMARIND" in joined, f"empty mapped-id call input lost; got {texts!r}"
assert "EMPTYID-MAPPED-OUTPUT-MARKER-SAFFRON" in joined, f"empty mapped-id output lost; got {texts!r}"
assert joined.count("[Orphan tool result:") == 1, f"empty mapped-id output should orphan-flag; got {texts!r}"
for r in records:
    for block in r.get("message", {}).get("content", []):
        assert block.get("type") != "tool_use", f"empty mapped-id call should not emit Claude tool_use: {records!r}"
print("empty mapped function_call id folds and orphans PASSED")
EOF

# ---------------------------------------------------------------------------
# EE (review #8 GLM BUG): Claude user records with `content` as a plain string
# (~17% of real local user records, 2026-05-04 corpus scan) must survive
# claude-to-codex conversion. Pre-fix: the input loop's
# `if not isinstance(content, list): continue` silently dropped these, losing
# user prompts in any session that mixed string-form and list-form turns. The
# list-form path must also render Claude image blocks as explicit omission
# markers, matching the Codex -> Claude image boundary instead of dropping
# them silently.
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
     "message":{"role":"user","content":[{"type":"text","text":"LIST-FORM-USER-PROMPT-VANILLA"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}},
    {"type":"user","uuid":"u3","parentUuid":"u2","sessionId":uuid_,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:02.000Z","isSidechain":False,
     "message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"BBBB"}}]}},
    {"type":"user","uuid":"u4","parentUuid":"u3","sessionId":uuid_,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:03.000Z","isSidechain":False,
     "message":{"role":"user","content":"   "}},
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
assert joined.count("Claude user image attachment omitted") == 2, \
    f"Claude image block was silently dropped; got {joined!r}"
assert any(msg == "   " for msg in user_msgs), \
    f"whitespace-only Claude user prompt was dropped; got {user_msgs!r}"
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
    *"--target-cwd must not be empty or whitespace-only"*)
        [ "$HH_RC" -ne 0 ] || { echo "FAIL: empty --target-cwd accepted by Python entry point"; exit 1; }
        ;;
    *)
        echo "FAIL: expected empty-target-cwd ValueError (codex-to-claude), got rc=$HH_RC stderr=$HH_STDERR"
        exit 1
        ;;
esac
# Whitespace-only --target-cwd must also be rejected (round-10 follow-up:
# DeepSeek POLISH — `not target_cwd` lets `"   "` through Python truthiness;
# `not target_cwd.strip()` closes the same class of bypass).
set +e
HH_WS_STDERR=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$HH_SRC_UUID" --target-cwd "   " 2>&1 >/dev/null)
HH_WS_RC=$?
set -e
case "$HH_WS_STDERR" in
    *"--target-cwd must not be empty or whitespace-only"*)
        [ "$HH_WS_RC" -ne 0 ] || { echo "FAIL: whitespace-only --target-cwd accepted by codex-to-claude"; exit 1; }
        ;;
    *)
        echo "FAIL: expected whitespace-only-target-cwd ValueError (codex-to-claude), got rc=$HH_WS_RC stderr=$HH_WS_STDERR"
        exit 1
        ;;
esac
# claude-to-codex direction parity check (review-#9 internal: round-8 only
# tested codex-to-claude; this exercises the mirror code path that round 8
# also added the guard to).
HH_CLAUDE_SRC_UUID="00000000-0000-4000-8000-deadbeef00cd"
HH_CLAUDE_SRC="$CLAUDE_HOME/projects/$ENCODED_CWD/$HH_CLAUDE_SRC_UUID.jsonl"
python3 - "$HH_CLAUDE_SRC" "$HH_CLAUDE_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"type":"user","uuid":"u1","parentUuid":None,"sessionId":uuid_,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:00.000Z","isSidechain":False,
     "message":{"role":"user","content":"hi"}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
set +e
HH_C2C_STDERR=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$HH_CLAUDE_SRC_UUID" --target-cwd "" 2>&1 >/dev/null)
HH_C2C_RC=$?
set -e
case "$HH_C2C_STDERR" in
    *"--target-cwd must not be empty or whitespace-only"*)
        [ "$HH_C2C_RC" -ne 0 ] || { echo "FAIL: empty --target-cwd accepted by claude-to-codex entry"; exit 1; }
        ;;
    *)
        echo "FAIL: expected empty-target-cwd ValueError (claude-to-codex), got rc=$HH_C2C_RC stderr=$HH_C2C_STDERR"
        exit 1
        ;;
esac
# Whitespace-only parity check on claude-to-codex (round-10 follow-up).
set +e
HH_C2C_WS_STDERR=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$HH_CLAUDE_SRC_UUID" --target-cwd $'  	  ' 2>&1 >/dev/null)
HH_C2C_WS_RC=$?
set -e
case "$HH_C2C_WS_STDERR" in
    *"--target-cwd must not be empty or whitespace-only"*)
        [ "$HH_C2C_WS_RC" -ne 0 ] || { echo "FAIL: whitespace-only --target-cwd accepted by claude-to-codex"; exit 1; }
        echo "Python-side empty + whitespace --target-cwd rejection (both directions) PASSED"
        ;;
    *)
        echo "FAIL: expected whitespace-only-target-cwd ValueError (claude-to-codex), got rc=$HH_C2C_WS_RC stderr=$HH_C2C_WS_STDERR"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# II (review-#9 internal): mirror of GG. Round 8 promoted pending_start
# scalar to a stack to handle nested task_started; GG covers the
# "inner aborts, outer completes" path. This scenario covers the OTHER
# stack code path: "inner completes, outer aborts" — verifying the
# task_complete pop AND a later turn_aborted's pop on the outer index
# both work as intended. Without scenario II, half the stack's behavior
# is structurally unexercised by tests.
# ---------------------------------------------------------------------------
II_SRC_UUID="019dee99-aabb-7000-8000-deadbeef0011"
II_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-${II_SRC_UUID}.jsonl"
python3 - "$II_SRC" "$II_SRC_UUID" "$CWD" <<'PY'
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
    msg("OUTER-DOOMED-PRE", "2026-05-04T00:00:01.000Z"),
    life("task_started",  "2026-05-04T00:00:02.000Z"),  # outer
    msg("OUTER-DOOMED-PRE-INNER", "2026-05-04T00:00:03.000Z"),
    life("task_started",  "2026-05-04T00:00:04.000Z"),  # inner
    msg("INNER-OK-CONTENT", "2026-05-04T00:00:05.000Z"),
    life("task_complete", "2026-05-04T00:00:06.000Z"),  # inner completes cleanly
    msg("OUTER-DOOMED-POST-INNER", "2026-05-04T00:00:07.000Z"),
    life("turn_aborted",  "2026-05-04T00:00:08.000Z"),  # aborts outer
    msg("OUTER-AFTER-ABORT-NEW-TURN", "2026-05-04T00:00:09.000Z"),
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
II_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$II_SRC_UUID")
II_NEW_PATH=$(echo "$II_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
python3 - "$II_NEW_PATH" <<'EOF'
import json, sys
records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
joined = "\n".join(
    b.get("text","")
    for r in records
    for b in r.get("message",{}).get("content",[])
    if isinstance(b, dict)
)
# Outer-task content (between outer task_started and turn_aborted) must
# be filtered. This includes content emitted both before the inner
# task_started ('OUTER-DOOMED-PRE-INNER') AND after the inner's clean
# task_complete ('OUTER-DOOMED-POST-INNER'). The inner that completed
# cleanly is conceptually inside the outer, so its content is also
# filtered when the outer aborts — this is the strict semantic of
# nested task abortion.
for gone in ("OUTER-DOOMED-PRE-INNER", "OUTER-DOOMED-POST-INNER",
             "INNER-OK-CONTENT"):
    assert gone not in joined, \
        f"outer-aborted nested content {gone!r} leaked: {joined!r}"
# Content emitted BEFORE the outer task_started survives (it's not in
# any task scope — pre-task narrative).
assert "OUTER-DOOMED-PRE" in joined, \
    f"pre-task content lost: {joined!r}"
# Content emitted AFTER the outer's turn_aborted survives — that's a
# new turn's content, not part of the aborted task.
assert "OUTER-AFTER-ABORT-NEW-TURN" in joined, \
    f"post-abort content lost: {joined!r}"
print("nested task_complete + outer turn_aborted filters outer scope PASSED")
EOF

# ---------------------------------------------------------------------------
# JJ (review-#9 internal, Gemini round-8 GAP): structural multi-hop
# A->B->A->B stability test. The fold-to-text branches for unmapped tools
# write narrative like "[Used Codex tool 'web_search_call' with arguments:
# ...]" into a message/content text block. On a second hop, that text is
# re-read as plain user/assistant text (NOT re-parsed as a tool call),
# so the prefix should NOT stack ("[Used Codex tool ... [Used Codex tool
# ...]]"). This pin asserts the property on synthetic input across 4 hops.
# ---------------------------------------------------------------------------
JJ_CODEX_UUID="019dee99-ccdd-7000-8000-deadbeef0022"
JJ_CODEX_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-${JJ_CODEX_UUID}.jsonl"
python3 - "$JJ_CODEX_SRC" "$JJ_CODEX_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":uuid_,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"codex","cli_version":"0.0.0-test","source":"cli","model_provider":"openai","base_instructions":{"text":"x"}}},
    # An UNMAPPED tool call (web_search_call) that will fold to text
    # on every cross-vendor conversion.
    {"timestamp":"2026-05-04T00:00:01.000Z","type":"response_item","payload":{"type":"web_search_call","id":"ws_jj","status":"completed","action":{"type":"search","query":"JJ-MULTIHOP-MARKER-NUTMEG"}}},
    {"timestamp":"2026-05-04T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"final answer"}],"phase":"commentary"}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
# Hop 1: codex -> claude
JJ_H1_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$JJ_CODEX_UUID")
JJ_H1_UUID=$(echo "$JJ_H1_OUT" | awk '/^new session UUID:/ {print $NF}')
# Hop 2: claude -> codex
JJ_H2_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$JJ_H1_UUID")
JJ_H2_UUID=$(echo "$JJ_H2_OUT" | awk '/^new session UUID:/ {print $NF}')
# Hop 3: codex -> claude
JJ_H3_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$JJ_H2_UUID")
JJ_H3_UUID=$(echo "$JJ_H3_OUT" | awk '/^new session UUID:/ {print $NF}')
# Hop 4: claude -> codex
JJ_H4_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$JJ_H3_UUID")
JJ_H4_UUID=$(echo "$JJ_H4_OUT" | awk '/^new session UUID:/ {print $NF}')
JJ_H4_PATH=$(echo "$JJ_H4_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
python3 - "$JJ_H4_PATH" <<'EOF'
import json, sys
content_text_chunks = []
for line in open(sys.argv[1]):
    if not line.strip(): continue
    r = json.loads(line)
    if r.get("type") == "response_item":
        p = r.get("payload", {})
        if p.get("type") == "message":
            for b in p.get("content", []):
                if isinstance(b, dict):
                    content_text_chunks.append(b.get("text", ""))
all_text = "\n".join(content_text_chunks)
# The marker survives 4 hops because it's embedded in the fold-to-text.
assert "JJ-MULTIHOP-MARKER-NUTMEG" in all_text, \
    f"multi-hop content loss: {all_text!r}"
# Critical stability property: the [Used Codex tool ...] prefix appears
# at most ONCE per chunk, even across 4 hops. If prefixes stacked we'd
# see "[Used Codex tool 'web_search_call' ... [Used Codex tool ...".
nested_prefix = all_text.count("[Used Codex tool")
double_nested = "[Used Codex tool" + " " * 0 + " " in all_text and \
                all_text.find("[Used Codex tool", all_text.find("[Used Codex tool") + 1) != -1 and \
                all_text.find("[Used Codex tool", all_text.find("[Used Codex tool") + 1) < all_text.find("]")
# Simpler: assert no chunk has two "[Used Codex tool" before its closing "]".
for chunk in content_text_chunks:
    if "[Used Codex tool" in chunk:
        # Find first occurrence and the closing bracket; if a second
        # "[Used Codex tool" lives before the closing, that's stacking.
        first = chunk.find("[Used Codex tool")
        close = chunk.find("]", first)
        between = chunk[first + 1: close if close != -1 else len(chunk)]
        assert "[Used Codex tool" not in between, \
            f"fold prefix stacked across hops: {chunk!r}"
print("multi-hop A->B->A->B fold-to-text stability PASSED")
EOF

# ---------------------------------------------------------------------------
# KK (review-#9 internal, DeepSeek/Kimi round-8 POLISH): _warn_unknown
# dedupe is per-(category, kind) and uncapped. A pathological future
# schema with many distinct unknown kinds could flood stderr — this test
# pins the contract: N distinct unknown kinds emit at most N warnings
# total (one per kind), and the converter completes successfully.
# ---------------------------------------------------------------------------
KK_SRC_UUID="019dee99-eeff-7000-8000-deadbeef0033"
KK_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-${KK_SRC_UUID}.jsonl"
python3 - "$KK_SRC" "$KK_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":uuid_,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"codex","cli_version":"0.0.0-test","source":"cli","model_provider":"openai","base_instructions":{"text":"x"}}},
]
# 50 distinct unknown event_msg payload types.
for i in range(50):
    records.append({"timestamp":f"2026-05-04T00:00:{i+1:02d}.000Z","type":"event_msg","payload":{"type":f"future_kind_kk_{i:03d}"}})
# Plus 50 duplicates of one of them (to verify dedupe works at scale).
for i in range(50):
    records.append({"timestamp":f"2026-05-04T00:01:{i:02d}.000Z","type":"event_msg","payload":{"type":"future_kind_kk_000"}})
records.append({"timestamp":"2026-05-04T00:02:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}],"phase":"commentary"}})
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
KK_STDERR_FILE="$SANDBOX/kk_stderr.txt"
CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$KK_SRC_UUID" \
    >/dev/null 2>"$KK_STDERR_FILE"
python3 - "$KK_STDERR_FILE" <<'EOF'
import sys
err = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
warning_lines = [l for l in err.splitlines() if "unhandled event_msg.payload type" in l]
# 50 distinct kinds + 50 duplicates of kind_000 = 50 unique warnings.
assert len(warning_lines) == 50, \
    f"expected 50 dedupe'd warnings, got {len(warning_lines)}:\n{err}"
# Each warning is for a distinct kind (no duplicates).
kinds = set()
for line in warning_lines:
    for i in range(50):
        marker = f"future_kind_kk_{i:03d}"
        if marker in line:
            kinds.add(marker)
            break
assert len(kinds) == 50, f"warning kinds not all distinct: {kinds}"
print("unknown-type dedupe scales to many distinct kinds PASSED")
EOF



# ---------------------------------------------------------------------------
# LL (issue #6 sub-bullet 1, Greptile P2): orphan function_call_output
# (a Codex response_item.function_call_output whose call_id has no
# matching response_item.function_call) must fold to an `[Orphan tool
# result: ...]` user text record, parity with the custom_tool_call_output
# orphan branch and the README's explicit "broken linkage" contract.
# Pre-#6 the converter emitted bare `str(output)` with no wrapper, which
# surfaced as an unexplained user message to the receiving Claude model.
# ---------------------------------------------------------------------------
LL_SRC_UUID="019dee99-1006-7000-8000-deadbeef0066"
LL_SRC="$CODEX_HOME/sessions/2026/05/04/rollout-2026-05-04T00-00-00-${LL_SRC_UUID}.jsonl"
python3 - "$LL_SRC" "$LL_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":uuid_,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"codex","cli_version":"0.0.0-test","source":"cli","model_provider":"openai","base_instructions":{"text":"x"}}},
    # Orphan output: a function_call_output with a call_id that has no
    # matching function_call upstream. The previous converter produced
    # bare `str(output)`; #6 changes this to `[Orphan tool result: ...]`.
    {"timestamp":"2026-05-04T00:00:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_orphan_LL","output":"LL-ORPHAN-OUTPUT-PAYLOAD"}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
LL_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$LL_SRC_UUID")
LL_NEW_UUID=$(echo "$LL_OUT" | awk '/^new session UUID:/ {print $NF}')
LL_NEW_PATH=$(echo "$LL_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
python3 - "$LL_NEW_PATH" <<'EOF'
import json, sys
joined = []
for line in open(sys.argv[1]):
    if not line.strip(): continue
    r = json.loads(line)
    if r.get("type") != "user": continue
    msg = r.get("message", {})
    for b in msg.get("content", []) if isinstance(msg.get("content"), list) else []:
        if isinstance(b, dict) and b.get("type") == "text":
            joined.append(b.get("text", ""))
all_text = "\n".join(joined)
assert "[Orphan tool result: LL-ORPHAN-OUTPUT-PAYLOAD]" in all_text, \
    f"orphan FCO not wrapped in [Orphan tool result: ...]: {all_text!r}"
# Also assert the bare-text form is NOT present (regression of pre-#6 shape).
assert all_text.count("LL-ORPHAN-OUTPUT-PAYLOAD") == 1, \
    f"orphan output should appear exactly once, wrapped: {all_text!r}"
# And confirm the wrapped chunk doesn't double-wrap.
import re
unwrapped = re.findall(r"^LL-ORPHAN-OUTPUT-PAYLOAD$", all_text, flags=re.MULTILINE)
assert not unwrapped, f"orphan output leaked unwrapped: {unwrapped!r}"
print("orphan function_call_output wrapped as [Orphan tool result: ...] PASSED")
EOF

# ---------------------------------------------------------------------------
# MM (issue #6 sub-bullet 2a/2b, Greptile P2 + empirical schema fix):
# default claude_to_codex without policy flags must emit:
#   approval_policy = "on-request"   (was hardcoded "never")
#   sandbox_policy  = {"type": "read-only"}  (was {"mode": "read-only"} —
#                       Codex's tagged-union discriminator is `type`, not
#                       `mode`, per empirical scan of 4870 local rollouts)
# ---------------------------------------------------------------------------
MM_SRC_UUID="00000000-0000-4000-8000-deadbeef0077"
MM_SRC="$CLAUDE_HOME/projects/$ENCODED_CWD/$MM_SRC_UUID.jsonl"
python3 - "$MM_SRC" "$MM_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"type":"user","uuid":"u1","parentUuid":None,"sessionId":uuid_,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:00.000Z","isSidechain":False,
     "message":{"role":"user","content":"hi"}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
MM_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$MM_SRC_UUID")
MM_NEW_UUID=$(echo "$MM_OUT" | awk '/^new session UUID:/ {print $NF}')
MM_NEW_PATH=$(echo "$MM_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
python3 - "$MM_NEW_PATH" <<'EOF'
import json, sys
turn_context = None
for line in open(sys.argv[1]):
    if not line.strip(): continue
    r = json.loads(line)
    if r.get("type") == "turn_context":
        turn_context = r.get("payload", {})
        break
assert turn_context is not None, "no turn_context emitted"
assert turn_context.get("approval_policy") == "on-request", \
    f"default approval_policy should be on-request, got {turn_context.get('approval_policy')!r}"
sp = turn_context.get("sandbox_policy")
assert isinstance(sp, dict), f"sandbox_policy not dict: {sp!r}"
assert sp.get("type") == "read-only", \
    f"default sandbox_policy.type should be read-only, got {sp.get('type')!r}"
assert "mode" not in sp, \
    f"sandbox_policy must not use legacy 'mode' key (Codex uses 'type'): {sp!r}"
print("default approval_policy + correct sandbox_policy schema PASSED")
EOF

# ---------------------------------------------------------------------------
# NN (issue #6 sub-bullet 2c): each valid CLI enum value round-trips into
# turn_context. Iterates over every value of both flags.
# ---------------------------------------------------------------------------
NN_SRC_UUID="00000000-0000-4000-8000-deadbeef0088"
NN_SRC="$CLAUDE_HOME/projects/$ENCODED_CWD/$NN_SRC_UUID.jsonl"
python3 - "$NN_SRC" "$NN_SRC_UUID" "$CWD" <<'PY'
import json, sys
src, uuid_, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
records = [
    {"type":"user","uuid":"u1","parentUuid":None,"sessionId":uuid_,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:00.000Z","isSidechain":False,
     "message":{"role":"user","content":"hi"}},
]
with open(src,"w",encoding="utf-8") as f:
    for r in records: f.write(json.dumps(r)+"\n")
PY
for ap in untrusted on-request on-failure never; do
  for sp in read-only workspace-write danger-full-access; do
    NN_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
        python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$NN_SRC_UUID" \
        --codex-approval-policy "$ap" --codex-sandbox-policy "$sp")
    NN_PATH=$(echo "$NN_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
    python3 - "$NN_PATH" "$ap" "$sp" <<'EOF'
import json, sys
fp, ap_expected, sp_expected = sys.argv[1], sys.argv[2], sys.argv[3]
turn_context = None
for line in open(fp):
    if not line.strip(): continue
    r = json.loads(line)
    if r.get("type") == "turn_context":
        turn_context = r.get("payload", {})
        break
assert turn_context, "no turn_context"
assert turn_context.get("approval_policy") == ap_expected, \
    f"approval_policy round-trip failed: expected {ap_expected!r} got {turn_context.get('approval_policy')!r}"
sp_dict = turn_context.get("sandbox_policy", {})
assert sp_dict.get("type") == sp_expected, \
    f"sandbox_policy.type round-trip failed: expected {sp_expected!r} got {sp_dict.get('type')!r}"
EOF
  done
done
echo "approval_policy + sandbox_policy CLI flags round-trip across full enum PASSED"

# ---------------------------------------------------------------------------
# OO (issue #6 sub-bullet 2d/2e): workspace-write must include the four
# sub-fields with conservative defaults; invalid enum values must be
# rejected by Python argparse with exit 2 and a clear error.
# ---------------------------------------------------------------------------
OO_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$NN_SRC_UUID" \
    --codex-sandbox-policy workspace-write)
OO_PATH=$(echo "$OO_OUT" | awk -F'-> ' '/^converted:/ {print $2}')
python3 - "$OO_PATH" "$CWD" <<'EOF'
import json, sys, os
fp, expected_cwd = sys.argv[1], sys.argv[2]
turn_context = None
for line in open(fp):
    if not line.strip(): continue
    r = json.loads(line)
    if r.get("type") == "turn_context":
        turn_context = r.get("payload", {})
        break
assert turn_context, "no turn_context"
sp = turn_context.get("sandbox_policy", {})
assert sp.get("type") == "workspace-write", f"type wrong: {sp!r}"
# Conservative defaults: cwd as the only writable root, no network, no
# tmp exclusions. Realpath because converter realpaths the cwd.
# Empirical default: 1757/1801 native workspace-write rollouts have
# writable_roots = ['~/.codex/memories'] only (cwd is implicit under
# workspace-write). #6 updated the converter's default to match this
# dominant native pattern.
expected_writable = [os.path.expanduser('~/.codex/memories')]
assert sp.get("writable_roots") == expected_writable, \
    f"writable_roots default wrong: {sp.get('writable_roots')!r} (expected {expected_writable!r})"
assert sp.get("network_access") is False, f"network_access default wrong: {sp.get('network_access')!r}"
assert sp.get("exclude_tmpdir_env_var") is False, f"exclude_tmpdir_env_var wrong: {sp.get('exclude_tmpdir_env_var')!r}"
assert sp.get("exclude_slash_tmp") is False, f"exclude_slash_tmp wrong: {sp.get('exclude_slash_tmp')!r}"
print("workspace-write sub-fields populated with conservative defaults PASSED")
EOF

# Invalid enum values rejected at the Python boundary with exit 2.
set +e
OO_BAD_OUT=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$NN_SRC_UUID" \
    --codex-approval-policy bogus 2>&1 >/dev/null)
OO_BAD_RC=$?
set -e
case "$OO_BAD_OUT" in
    *"argument --codex-approval-policy"*"invalid choice"*)
        [ "$OO_BAD_RC" -ne 0 ] || { echo "FAIL: invalid --codex-approval-policy accepted (rc=0)"; exit 1; }
        ;;
    *)
        echo "FAIL: expected argparse 'invalid choice' for --codex-approval-policy bogus, got rc=$OO_BAD_RC stderr=$OO_BAD_OUT"
        exit 1
        ;;
esac
set +e
OO_BAD_SP=$(CODEX_HOME="$CODEX_HOME" CLAUDE_HOME="$CLAUDE_HOME" \
    python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$NN_SRC_UUID" \
    --codex-sandbox-policy nonsense 2>&1 >/dev/null)
OO_BAD_SP_RC=$?
set -e
case "$OO_BAD_SP" in
    *"argument --codex-sandbox-policy"*"invalid choice"*)
        [ "$OO_BAD_SP_RC" -ne 0 ] || { echo "FAIL: invalid --codex-sandbox-policy accepted (rc=0)"; exit 1; }
        echo "invalid --codex-{approval,sandbox}-policy values rejected by argparse PASSED"
        ;;
    *)
        echo "FAIL: expected argparse 'invalid choice' for --codex-sandbox-policy nonsense, got rc=$OO_BAD_SP_RC stderr=$OO_BAD_SP"
        exit 1
        ;;
esac

# Also assert the wrapper rejects BOTH --codex-approval-policy and
# --codex-sandbox-policy on the wrong direction (handoff-to-claude has
# no turn_context to populate). Symmetric pin so the wrapper's two
# direction-guards stay covered together — if one regresses while the
# other is still tested, we'd ship a half-broken validator.
set +e
OO_WRONG_DIR=$("$REPO_ROOT/second-codex" handoff-to-claude "$LL_SRC_UUID" --codex-approval-policy never 2>&1 >/dev/null)
OO_WRONG_DIR_RC=$?
set -e
case "$OO_WRONG_DIR" in
    *"only valid on handoff-from-claude"*)
        [ "$OO_WRONG_DIR_RC" -ne 0 ] || { echo "FAIL: --codex-approval-policy accepted on handoff-to-claude (rc=0)"; exit 1; }
        ;;
    *)
        echo "FAIL: expected wrong-direction error for --codex-approval-policy on handoff-to-claude, got rc=$OO_WRONG_DIR_RC stderr=$OO_WRONG_DIR"
        exit 1
        ;;
esac
set +e
OO_WRONG_DIR_SP=$("$REPO_ROOT/second-codex" handoff-to-claude "$LL_SRC_UUID" --codex-sandbox-policy danger-full-access 2>&1 >/dev/null)
OO_WRONG_DIR_SP_RC=$?
set -e
case "$OO_WRONG_DIR_SP" in
    *"only valid on handoff-from-claude"*)
        [ "$OO_WRONG_DIR_SP_RC" -ne 0 ] || { echo "FAIL: --codex-sandbox-policy accepted on handoff-to-claude (rc=0)"; exit 1; }
        echo "wrapper rejects --codex-{approval,sandbox}-policy on wrong direction PASSED"
        ;;
    *)
        echo "FAIL: expected wrong-direction error for --codex-sandbox-policy on handoff-to-claude, got rc=$OO_WRONG_DIR_SP_RC stderr=$OO_WRONG_DIR_SP"
        exit 1
        ;;
esac

echo "all converter sandbox tests passed"
