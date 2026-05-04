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
mkdir -p "$CODEX_HOME/sessions/2026/05/04"
mkdir -p "$CLAUDE_HOME/projects/$(printf %s "$CWD" | tr / -)"

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
NEW_CLAUDE_PATH="$CLAUDE_HOME/projects/$(printf %s "$CWD" | tr / -)/$NEW_CLAUDE_UUID.jsonl"
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
CLAUDE_SRC="$CLAUDE_HOME/projects/$(printf %s "$CWD" | tr / -)/$CLAUDE_SRC_UUID.jsonl"
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
NEW_CLAUDE_PATH="$CLAUDE_HOME/projects/$(printf %s "$CWD" | tr / -)/$NEW_CLAUDE_UUID.jsonl"

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
CLAUDE_UNMAPPED="$CLAUDE_HOME/projects/$(printf %s "$CWD" | tr / -)/$CLAUDE_UNMAPPED_UUID.jsonl"
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

echo "all converter sandbox tests passed"
