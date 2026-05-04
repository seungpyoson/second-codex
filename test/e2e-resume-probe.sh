#!/usr/bin/env bash
# Manual end-to-end probe that the converters round-trip through the
# RECEIVERS' actual resume commands. Spends a tiny amount of API tokens
# (one short turn per direction). Not part of the standard sandbox
# because it requires network and live LLM credentials.
#
# Usage:
#   bash test/e2e-resume-probe.sh
#
# Asserts:
#   - codex-to-claude: claude --resume loads the converted session and the
#     model can recall a marker placed in the original Codex rollout.
#   - claude-to-codex: codex exec resume loads the converted rollout and
#     the model can recall a marker placed in the original Claude session.
#
# Both probes embed the marker in a *prior turn* of the source session
# (not the new prompt). A model can only return it if the receiver
# actually loaded the converted history into context — i.e. the receiver
# accepted the file's schema and the converter wrote it where the
# receiver looks.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_CWD="${PROBE_CWD:-/tmp/second-codex-e2e-cwd}"
mkdir -p "$PROBE_CWD"

# Use realpath so we land in the same encoded project directory that
# claude --resume scans. The converter does this internally; mirroring it
# here keeps the test's cleanup paths predictable.
PROBE_REAL_CWD="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$PROBE_CWD")"
ENCODED_DIR="$(python3 -c 'import os, re, sys; print(re.sub(r"[^A-Za-z0-9-]", "-", os.path.realpath(sys.argv[1])))' "$PROBE_CWD")"

CODEX_SRC_UUID="00000000-0000-7000-8000-e2e000000001"
CLAUDE_SRC_UUID="00000000-0000-4000-8000-e2e000000002"
CODEX_MARKER="E2E-CODEX-SOURCE-PUMPKIN-7711"
CLAUDE_MARKER="E2E-CLAUDE-SOURCE-CHESTNUT-9933"

# Surgical cleanup: only paths the probe creates. Critically, do NOT
# wildcard-delete *.jsonl under $ENCODED_DIR — a user pointing PROBE_CWD
# at a real working directory (e.g. PROBE_CWD=$HOME/Projects/foo) would
# otherwise lose every other Claude session for that project on cleanup.
# Each conversion's converted-output path is captured as it runs, below.
NEW_CLAUDE_PATH=""
NEW_CODEX_PATH=""

cleanup() {
    rm -f \
        "$HOME/.codex/sessions/2026/05/04/rollout-2026-05-04T00-00-00-$CODEX_SRC_UUID.jsonl" \
        "$HOME/.claude/projects/$ENCODED_DIR/$CLAUDE_SRC_UUID.jsonl" \
        ${NEW_CLAUDE_PATH:+"$NEW_CLAUDE_PATH"} \
        ${NEW_CODEX_PATH:+"$NEW_CODEX_PATH"}
    # rmdir is best-effort and only succeeds if the dir is empty — exactly
    # the safety we want: it leaves any unrelated user files in place.
    rmdir "$HOME/.claude/projects/$ENCODED_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- codex-to-claude ----------
mkdir -p "$HOME/.codex/sessions/2026/05/04"
python3 - "$CODEX_SRC_UUID" "$PROBE_REAL_CWD" "$CODEX_MARKER" <<'PY'
import json, os, sys
from pathlib import Path
src_uuid, cwd, marker = sys.argv[1], sys.argv[2], sys.argv[3]
src = Path.home() / ".codex/sessions/2026/05/04" / f"rollout-2026-05-04T00-00-00-{src_uuid}.jsonl"
records = [
    {"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":src_uuid,"timestamp":"2026-05-04T00:00:00.000Z","cwd":cwd,"originator":"second-codex-e2e","cli_version":"0.0.0-e2e","source":"cli","model_provider":"openai","base_instructions":{"text":"You are Codex, a coding agent.\n"}}},
    {"timestamp":"2026-05-04T00:00:01.000Z","type":"turn_context","payload":{"cwd":cwd,"approval_policy":"never","sandbox_policy":{"mode":"read-only"},"model":"gpt-5.5","effort":"none","summary":"none"}},
    {"timestamp":"2026-05-04T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":f"Earlier I asked you to remember the marker {marker}.","images":[],"local_images":[],"text_elements":[]}},
    {"timestamp":"2026-05-04T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":f"Acknowledged. The marker is {marker}."}],"phase":"commentary"}},
]
with src.open("w", encoding="utf-8") as f:
    for r in records:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

C2C_OUT="$(python3 "$REPO_ROOT/lib/session_convert.py" codex-to-claude "$CODEX_SRC_UUID")"
NEW_CLAUDE_UUID="$(echo "$C2C_OUT" | awk '/^new session UUID:/ {print $NF}')"
NEW_CLAUDE_PATH="$(echo "$C2C_OUT" | awk -F'-> ' '/^converted:/ {print $2}')"
[ -n "$NEW_CLAUDE_UUID" ] || { echo "FAIL: codex-to-claude did not print a new UUID"; exit 1; }
[ -n "$NEW_CLAUDE_PATH" ] || { echo "FAIL: codex-to-claude did not print a 'converted: ... -> <path>' line"; exit 1; }

cd "$PROBE_CWD"
CLAUDE_REPLY="$(claude --resume "$NEW_CLAUDE_UUID" --print "What was the marker I asked you to remember? Reply with just the marker." 2>&1 | tr -d '\r' | head -5)"
echo "[c2c] claude --resume reply: $CLAUDE_REPLY"
case "$CLAUDE_REPLY" in
    *"$CODEX_MARKER"*) echo "[c2c] PASS — claude resumed converted session and recalled the marker" ;;
    *"No conversation found"*) echo "[c2c] FAIL — claude could not find the converted session ($NEW_CLAUDE_UUID)"; exit 1 ;;
    *) echo "[c2c] FAIL — marker not recalled. reply was: $CLAUDE_REPLY"; exit 1 ;;
esac
cd "$REPO_ROOT"

# ---------- claude-to-codex ----------
mkdir -p "$HOME/.claude/projects/$ENCODED_DIR"
python3 - "$CLAUDE_SRC_UUID" "$PROBE_REAL_CWD" "$CLAUDE_MARKER" <<'PY'
import json, os, re, sys
from pathlib import Path
src_uuid, cwd, marker = sys.argv[1], sys.argv[2], sys.argv[3]
encoded = re.sub(r"[^A-Za-z0-9-]", "-", cwd)
proj = Path.home() / ".claude/projects" / encoded
proj.mkdir(parents=True, exist_ok=True)
src = proj / f"{src_uuid}.jsonl"
records = [
    {"type":"user","uuid":"u1","parentUuid":None,"sessionId":src_uuid,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:00.000Z","isSidechain":False,"message":{"role":"user","content":[{"type":"text","text":f"Earlier I asked you to remember the marker {marker}."}]}},
    {"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":src_uuid,"cwd":cwd,"version":"1.0.0","userType":"external","timestamp":"2026-05-04T00:00:01.000Z","isSidechain":False,"requestId":"req_e2e","message":{"id":"m1","type":"message","role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":f"Acknowledged. The marker is {marker}."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":10}}},
]
with src.open("w", encoding="utf-8") as f:
    for r in records:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

CC2_OUT="$(python3 "$REPO_ROOT/lib/session_convert.py" claude-to-codex "$CLAUDE_SRC_UUID")"
NEW_CODEX_UUID="$(echo "$CC2_OUT" | awk '/^new session UUID:/ {print $NF}')"
NEW_CODEX_PATH="$(echo "$CC2_OUT" | awk -F'-> ' '/^converted:/ {print $2}')"
[ -n "$NEW_CODEX_UUID" ] || { echo "FAIL: claude-to-codex did not print a new UUID"; exit 1; }
[ -n "$NEW_CODEX_PATH" ] || { echo "FAIL: claude-to-codex did not print a 'converted: ... -> <path>' line"; exit 1; }

cd "$PROBE_CWD"
CODEX_REPLY="$(codex exec --skip-git-repo-check resume "$NEW_CODEX_UUID" "What was the marker I asked you to remember? Reply with just the marker." 2>&1 | tr -d '\r' | tail -10)"
echo "[cc2] codex exec resume reply (last 10 lines):"
echo "$CODEX_REPLY"
case "$CODEX_REPLY" in
    *"$CLAUDE_MARKER"*) echo "[cc2] PASS — codex resumed converted rollout and recalled the marker" ;;
    *"trusted"*|*"directory"*) echo "[cc2] FAIL — codex refused; check --skip-git-repo-check is honored"; exit 1 ;;
    *) echo "[cc2] FAIL — marker not recalled."; exit 1 ;;
esac

echo ""
echo "all e2e resume probes PASSED"
