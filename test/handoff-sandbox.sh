#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-handoff-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

SESSION_ID="00000000-0000-7000-8000-000000000001"
OTHER_SESSION_ID="00000000-0000-7000-8000-000000000002"
SESSION_REL="2026/05/03/rollout-2026-05-03T19-03-47-$SESSION_ID.jsonl"
OTHER_SESSION_REL="2026/05/03/rollout-2026-05-03T19-04-47-$OTHER_SESSION_ID.jsonl"

mkdir -p "$SANDBOX/home-a" "$SANDBOX/home-second/sessions/2026/05/03"
cat > "$SANDBOX/home-second/history.jsonl" <<EOF
{"session_id":"$SESSION_ID","ts":1760000000,"text":"continue this work"}
{"session_id":"$OTHER_SESSION_ID","ts":1760000001,"text":"other work"}
EOF
cat > "$SANDBOX/home-second/sessions/$SESSION_REL" <<EOF
{"type":"session_meta","payload":{"id":"$SESSION_ID","cwd":"/tmp/project"}}
{"type":"turn_context","payload":{"cwd":"/tmp/project"}}
EOF
cat > "$SANDBOX/home-second/sessions/$OTHER_SESSION_REL" <<EOF
{"type":"session_meta","payload":{"id":"$OTHER_SESSION_ID","cwd":"/tmp/other"}}
{"type":"turn_context","payload":{"cwd":"/tmp/other"}}
EOF
cat > "$SANDBOX/home-second/auth.json" <<'EOF'
{"secret":"do-not-copy"}
EOF

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" session-id > "$SANDBOX/session-id.out"
grep -Fxq "$OTHER_SESSION_ID" "$SANDBOX/session-id.out"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" session-id --second /tmp/project > "$SANDBOX/session-id-cwd.out"
grep -Fxq "$SESSION_ID" "$SANDBOX/session-id-cwd.out"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" handoff --last --cwd /tmp/project > "$SANDBOX/handoff.out"

grep -Fxq "session_id=$SESSION_ID" "$SANDBOX/handoff.out"
grep -Fxq "resume_primary_interactive=codex resume $SESSION_ID" "$SANDBOX/handoff.out"
grep -Fxq "resume_primary_exec=codex exec resume $SESSION_ID" "$SANDBOX/handoff.out"
cmp -s "$SANDBOX/home-second/sessions/$SESSION_REL" "$SANDBOX/home-a/sessions/$SESSION_REL"
grep -Fq "\"session_id\":\"$SESSION_ID\"" "$SANDBOX/home-a/history.jsonl"
test ! -e "$SANDBOX/home-a/auth.json"

echo '{"different":"primary transcript"}' > "$SANDBOX/home-a/sessions/$SESSION_REL"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "$SESSION_ID" >"$SANDBOX/refuse.out" 2>&1; then
  echo "FAIL handoff overwrote a different primary transcript"
  exit 1
fi
grep -q "refused to overwrite different primary session file" "$SANDBOX/refuse.out"

echo "PASS handoff sandbox"
