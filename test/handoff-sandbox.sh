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
"$REPO_ROOT/second-codex" session-id /tmp/project > "$SANDBOX/session-id-positional-cwd.out"
grep -Fxq "$SESSION_ID" "$SANDBOX/session-id-positional-cwd.out"

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" session-id --primary --foo >"$SANDBOX/session-id-bad-option.out" 2>&1; then
  echo "FAIL session-id accepted option-looking cwd"
  exit 1
fi
grep -q "usage: second-codex session-id" "$SANDBOX/session-id-bad-option.out"

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_TEST_DISABLE_PYTHON3=1 \
  "$REPO_ROOT/second-codex" handoff --last --cwd /tmp/project >"$SANDBOX/no-python-cwd.out" 2>&1; then
  echo "FAIL cwd-filtered handoff ignored missing python3"
  exit 1
fi
grep -q "cannot filter sessions by cwd" "$SANDBOX/no-python-cwd.out"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_TEST_DISABLE_PYTHON3=1 \
"$REPO_ROOT/second-codex" _session-hint second /tmp/project >"$SANDBOX/no-python-hint.out"
grep -q "python3 not found" "$SANDBOX/no-python-hint.out"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" handoff --last --cwd /tmp/project > "$SANDBOX/handoff.out"

grep -Fxq "session_id=$SESSION_ID" "$SANDBOX/handoff.out"
grep -Fxq "resume_primary_interactive=codex resume $SESSION_ID" "$SANDBOX/handoff.out"
grep -Fxq "resume_primary_exec=codex exec resume $SESSION_ID" "$SANDBOX/handoff.out"
grep -Fxq "resume_second_interactive=second-codex resume $SESSION_ID" "$SANDBOX/handoff.out"
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

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "$OTHER_SESSION_ID" --last >"$SANDBOX/id-plus-last.out" 2>&1; then
  echo "FAIL handoff allowed explicit session id with --last"
  exit 1
fi
grep -q "cannot combine an explicit session id with --last" "$SANDBOX/id-plus-last.out"

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff --last "$OTHER_SESSION_ID" >"$SANDBOX/last-plus-id.out" 2>&1; then
  echo "FAIL handoff allowed --last with explicit session id"
  exit 1
fi
grep -q "cannot combine an explicit session id with --last" "$SANDBOX/last-plus-id.out"

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "../../bad" >"$SANDBOX/bad-id.out" 2>&1; then
  echo "FAIL malformed handoff session id was not refused"
  exit 1
fi
grep -q "refused malformed session id" "$SANDBOX/bad-id.out"

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$SANDBOX/bad-uuid.out" 2>&1; then
  echo "FAIL non-UUID handoff session id was not refused"
  exit 1
fi
grep -q "refused malformed session id" "$SANDBOX/bad-uuid.out"

ATTACK_SESSION_ID="00000000-0000-7000-8000-000000000004"
ATTACK_REL="2026/05/03/rollout-2026-05-03T19-06-47-$ATTACK_SESSION_ID.jsonl"
ATTACK_COLLISION_REL="2026/05/03/zzzz-evil-$ATTACK_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-second/history.jsonl" <<EOF
{"session_id":"$ATTACK_SESSION_ID","ts":1760000003,"text":"attack collision work"}
EOF
cat > "$SANDBOX/home-second/sessions/$ATTACK_REL" <<EOF
{"type":"session_meta","payload":{"id":"$ATTACK_SESSION_ID","cwd":"/tmp/project"}}
{"type":"turn_context","payload":{"cwd":"/tmp/project","text":"LEGIT CONTENT"}}
EOF
cat > "$SANDBOX/home-second/sessions/$ATTACK_COLLISION_REL" <<EOF
{"type":"session_meta","payload":{"id":"99999999-9999-9999-9999-999999999999","cwd":"/tmp/project"}}
{"type":"turn_context","payload":{"cwd":"/tmp/project","text":"ATTACKER PLANTED CONTENT"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" handoff "$ATTACK_SESSION_ID" >"$SANDBOX/collision.out"
cmp -s "$SANDBOX/home-second/sessions/$ATTACK_REL" "$SANDBOX/home-a/sessions/$ATTACK_REL"
test ! -e "$SANDBOX/home-a/sessions/$ATTACK_COLLISION_REL"

PRETTY_SESSION_ID="00000000-0000-7000-8000-000000000008"
PRETTY_REL="2026/05/03/rollout-2026-05-03T19-10-47-$PRETTY_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-second/history.jsonl" <<EOF
{"session_id":"$PRETTY_SESSION_ID","ts":1760000008,"text":"pretty session work"}
EOF
cat > "$SANDBOX/home-second/sessions/$PRETTY_REL" <<EOF
{
  "type": "session_meta",
  "payload": {
    "id": "$PRETTY_SESSION_ID",
    "cwd": "/tmp/project"
  }
}
{"type":"turn_context","payload":{"cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" handoff "$PRETTY_SESSION_ID" >"$SANDBOX/pretty.out"
cmp -s "$SANDBOX/home-second/sessions/$PRETTY_REL" "$SANDBOX/home-a/sessions/$PRETTY_REL"

SYMLINK_TARGET_SESSION_ID="00000000-0000-7000-8000-000000000005"
SYMLINK_TARGET_REL="2026/05/03/rollout-2026-05-03T19-07-47-$SYMLINK_TARGET_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-second/history.jsonl" <<EOF
{"session_id":"$SYMLINK_TARGET_SESSION_ID","ts":1760000004,"text":"symlink target work"}
EOF
cat > "$SANDBOX/home-second/sessions/$SYMLINK_TARGET_REL" <<EOF
{"type":"session_meta","payload":{"id":"$SYMLINK_TARGET_SESSION_ID","cwd":"/tmp/project"}}
EOF
mkdir -p "$(dirname "$SANDBOX/home-a/sessions/$SYMLINK_TARGET_REL")"
ln -s "$SANDBOX/redirected-session.jsonl" "$SANDBOX/home-a/sessions/$SYMLINK_TARGET_REL"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "$SYMLINK_TARGET_SESSION_ID" >"$SANDBOX/target-symlink.out" 2>&1; then
  echo "FAIL handoff followed a target session symlink"
  exit 1
fi
grep -q "refused to overwrite symlink" "$SANDBOX/target-symlink.out"
test ! -e "$SANDBOX/redirected-session.jsonl"

INTERMEDIATE_SYMLINK_SESSION_ID="00000000-0000-7000-8000-000000000006"
INTERMEDIATE_SYMLINK_REL="2026/05/04/rollout-2026-05-04T19-08-47-$INTERMEDIATE_SYMLINK_SESSION_ID.jsonl"
mkdir -p "$SANDBOX/home-second/sessions/2026/05/04"
cat >> "$SANDBOX/home-second/history.jsonl" <<EOF
{"session_id":"$INTERMEDIATE_SYMLINK_SESSION_ID","ts":1760000006,"text":"intermediate symlink work"}
EOF
cat > "$SANDBOX/home-second/sessions/$INTERMEDIATE_SYMLINK_REL" <<EOF
{"type":"session_meta","payload":{"id":"$INTERMEDIATE_SYMLINK_SESSION_ID","cwd":"/tmp/project"}}
EOF
mkdir -p "$SANDBOX/home-a/sessions/2026/05" "$SANDBOX/redirected-dir"
ln -s "$SANDBOX/redirected-dir" "$SANDBOX/home-a/sessions/2026/05/04"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "$INTERMEDIATE_SYMLINK_SESSION_ID" >"$SANDBOX/intermediate-symlink.out" 2>&1; then
  echo "FAIL handoff followed an intermediate target directory symlink"
  exit 1
fi
grep -q "refused unsafe primary sessions path" "$SANDBOX/intermediate-symlink.out"
test -z "$(find "$SANDBOX/redirected-dir" -mindepth 1 -print -quit)"

ln -s "$SANDBOX/home-second" "$SANDBOX/home-second-link"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second-link" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "$SESSION_ID" >"$SANDBOX/source-symlink.out" 2>&1; then
  echo "FAIL handoff allowed symlinked second CODEX_HOME"
  exit 1
fi
grep -q "refused symlinked second CODEX_HOME" "$SANDBOX/source-symlink.out"

mkdir -p "$SANDBOX/unknown-second-home/sessions/2026/05/03"
cat > "$SANDBOX/unknown-second-home/history.jsonl" <<EOF
{"session_id":"$SESSION_ID","ts":1760000005,"text":"unknown work"}
EOF
cp "$SANDBOX/home-second/sessions/$SESSION_REL" "$SANDBOX/unknown-second-home/sessions/$SESSION_REL"
touch "$SANDBOX/unknown-second-home/unclassified"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/unknown-second-home" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" session-id >"$SANDBOX/session-id-unknown.out" 2>&1; then
  echo "FAIL session-id allowed unknown second CODEX_HOME entries"
  exit 1
fi
grep -q "unknown top-level entries" "$SANDBOX/session-id-unknown.out"

if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" session-id >"$SANDBOX/same-home.out" 2>&1; then
  echo "FAIL identical primary and second CODEX_HOME was not refused"
  exit 1
fi
grep -q "primary and second CODEX_HOME are the same" "$SANDBOX/same-home.out"

PRIMARY_ONLY_SESSION_ID="00000000-0000-7000-8000-000000000003"
PRIMARY_ONLY_REL="2026/05/03/rollout-2026-05-03T19-05-47-$PRIMARY_ONLY_SESSION_ID.jsonl"
mkdir -p "$SANDBOX/home-a/sessions/2026/05/03"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$PRIMARY_ONLY_SESSION_ID","ts":1760000002,"text":"primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$PRIMARY_ONLY_REL" <<EOF
{"type":"session_meta","payload":{"id":"$PRIMARY_ONLY_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume "$PRIMARY_ONLY_SESSION_ID" >"$SANDBOX/primary-only-resume.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/primary-only-resume.out"
cmp -s "$SANDBOX/home-a/sessions/$PRIMARY_ONLY_REL" "$SANDBOX/home-second/sessions/$PRIMARY_ONLY_REL"
grep -Fq "\"session_id\":\"$PRIMARY_ONLY_SESSION_ID\"" "$SANDBOX/home-second/history.jsonl"

FLAGGED_RESUME_SESSION_ID="00000000-0000-7000-8000-000000000007"
FLAGGED_RESUME_REL="2026/05/03/rollout-2026-05-03T19-09-47-$FLAGGED_RESUME_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$FLAGGED_RESUME_SESSION_ID","ts":1760000007,"text":"flagged primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$FLAGGED_RESUME_REL" <<EOF
{"type":"session_meta","payload":{"id":"$FLAGGED_RESUME_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" --config model=gpt-5.5 resume "$FLAGGED_RESUME_SESSION_ID" >"$SANDBOX/flagged-resume.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/flagged-resume.out"
cmp -s "$SANDBOX/home-a/sessions/$FLAGGED_RESUME_REL" "$SANDBOX/home-second/sessions/$FLAGGED_RESUME_REL"

SEPARATOR_RESUME_SESSION_ID="00000000-0000-7000-8000-000000000013"
SEPARATOR_RESUME_REL="2026/05/03/rollout-2026-05-03T19-14-47-$SEPARATOR_RESUME_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$SEPARATOR_RESUME_SESSION_ID","ts":1760000013,"text":"separator primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$SEPARATOR_RESUME_REL" <<EOF
{"type":"session_meta","payload":{"id":"$SEPARATOR_RESUME_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume -- "$SEPARATOR_RESUME_SESSION_ID" >"$SANDBOX/separator-resume.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/separator-resume.out"
cmp -s "$SANDBOX/home-a/sessions/$SEPARATOR_RESUME_REL" "$SANDBOX/home-second/sessions/$SEPARATOR_RESUME_REL"

RESUME_ALL_SESSION_ID="00000000-0000-7000-8000-000000000014"
RESUME_ALL_REL="2026/05/03/rollout-2026-05-03T19-15-47-$RESUME_ALL_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_ALL_SESSION_ID","ts":1760000014,"text":"resume all primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_ALL_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_ALL_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume --all "$RESUME_ALL_SESSION_ID" >"$SANDBOX/resume-all.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-all.out"
cmp -s "$SANDBOX/home-a/sessions/$RESUME_ALL_REL" "$SANDBOX/home-second/sessions/$RESUME_ALL_REL"

RESUME_INCLUDE_SESSION_ID="00000000-0000-7000-8000-000000000015"
RESUME_INCLUDE_REL="2026/05/03/rollout-2026-05-03T19-16-47-$RESUME_INCLUDE_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_INCLUDE_SESSION_ID","ts":1760000015,"text":"resume include primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_INCLUDE_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_INCLUDE_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume --include-non-interactive "$RESUME_INCLUDE_SESSION_ID" >"$SANDBOX/resume-include.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-include.out"
cmp -s "$SANDBOX/home-a/sessions/$RESUME_INCLUDE_REL" "$SANDBOX/home-second/sessions/$RESUME_INCLUDE_REL"

RESUME_CONFIG_SESSION_ID="00000000-0000-7000-8000-000000000016"
RESUME_CONFIG_REL="2026/05/03/rollout-2026-05-03T19-17-47-$RESUME_CONFIG_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_CONFIG_SESSION_ID","ts":1760000016,"text":"resume config primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_CONFIG_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_CONFIG_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume -c model=gpt-5.5 "$RESUME_CONFIG_SESSION_ID" >"$SANDBOX/resume-config.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-config.out"
cmp -s "$SANDBOX/home-a/sessions/$RESUME_CONFIG_REL" "$SANDBOX/home-second/sessions/$RESUME_CONFIG_REL"

RESUME_REMOTE_SESSION_ID="00000000-0000-7000-8000-000000000017"
RESUME_REMOTE_REL="2026/05/03/rollout-2026-05-03T19-18-47-$RESUME_REMOTE_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_REMOTE_SESSION_ID","ts":1760000017,"text":"resume remote primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_REMOTE_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_REMOTE_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume --remote ws://127.0.0.1:1 "$RESUME_REMOTE_SESSION_ID" >"$SANDBOX/resume-remote.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-remote.out"
cmp -s "$SANDBOX/home-a/sessions/$RESUME_REMOTE_REL" "$SANDBOX/home-second/sessions/$RESUME_REMOTE_REL"

RESUME_LAST_PROMPT_SESSION_ID="00000000-0000-7000-8000-000000000018"
RESUME_LAST_PROMPT_REL="2026/05/03/rollout-2026-05-03T19-19-47-$RESUME_LAST_PROMPT_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_LAST_PROMPT_SESSION_ID","ts":1760000018,"text":"resume last prompt primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_LAST_PROMPT_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_LAST_PROMPT_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume --last "$RESUME_LAST_PROMPT_SESSION_ID" >"$SANDBOX/resume-last-prompt.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
if grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-last-prompt.out"; then
  echo "FAIL resume --last prompt text triggered primary session import"
  exit 1
fi
test ! -e "$SANDBOX/home-second/sessions/$RESUME_LAST_PROMPT_REL"

RESUME_HELP_PROMPT_SESSION_ID="00000000-0000-7000-8000-000000000019"
RESUME_HELP_PROMPT_REL="2026/05/03/rollout-2026-05-03T19-20-47-$RESUME_HELP_PROMPT_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_HELP_PROMPT_SESSION_ID","ts":1760000019,"text":"resume help prompt primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_HELP_PROMPT_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_HELP_PROMPT_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume --help "$RESUME_HELP_PROMPT_SESSION_ID" >"$SANDBOX/resume-help-prompt.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
if grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-help-prompt.out"; then
  echo "FAIL resume --help prompt text triggered primary session import"
  exit 1
fi
test ! -e "$SANDBOX/home-second/sessions/$RESUME_HELP_PROMPT_REL"

RESUME_SHORT_HELP_PROMPT_SESSION_ID="00000000-0000-7000-8000-000000000020"
RESUME_SHORT_HELP_PROMPT_REL="2026/05/03/rollout-2026-05-03T19-21-47-$RESUME_SHORT_HELP_PROMPT_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_SHORT_HELP_PROMPT_SESSION_ID","ts":1760000020,"text":"resume short help prompt primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_SHORT_HELP_PROMPT_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_SHORT_HELP_PROMPT_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume -h "$RESUME_SHORT_HELP_PROMPT_SESSION_ID" >"$SANDBOX/resume-short-help-prompt.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
if grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-short-help-prompt.out"; then
  echo "FAIL resume -h prompt text triggered primary session import"
  exit 1
fi
test ! -e "$SANDBOX/home-second/sessions/$RESUME_SHORT_HELP_PROMPT_REL"

COLLISION_IMPORT_SESSION_ID="00000000-0000-7000-8000-000000000012"
COLLISION_IMPORT_REL="2026/05/03/rollout-2026-05-03T19-13-47-$COLLISION_IMPORT_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$COLLISION_IMPORT_SESSION_ID","ts":1760000012,"text":"collision import primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$COLLISION_IMPORT_REL" <<EOF
{"type":"session_meta","payload":{"id":"$COLLISION_IMPORT_SESSION_ID","cwd":"/tmp/project"}}
EOF
cat > "$SANDBOX/home-second/sessions/2026/05/03/evil-$COLLISION_IMPORT_SESSION_ID.jsonl" <<EOF
{"type":"session_meta","payload":{"id":"99999999-9999-9999-9999-999999999999","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume "$COLLISION_IMPORT_SESSION_ID" >"$SANDBOX/collision-import.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/collision-import.out"
cmp -s "$SANDBOX/home-a/sessions/$COLLISION_IMPORT_REL" "$SANDBOX/home-second/sessions/$COLLISION_IMPORT_REL"

PROMPT_RESUME_SESSION_ID="00000000-0000-7000-8000-000000000009"
PROMPT_RESUME_REL="2026/05/03/rollout-2026-05-03T19-11-47-$PROMPT_RESUME_SESSION_ID.jsonl"
mkdir -p "$SANDBOX/prompt-home-a/sessions/2026/05/03" "$SANDBOX/prompt-home-a/memories" "$SANDBOX/prompt-home-a/memories_extensions" "$SANDBOX/prompt-home-second"
cat > "$SANDBOX/prompt-home-a/config.toml" <<EOF
model = "gpt-5.5"
EOF
ln -s "$SANDBOX/prompt-home-a/memories" "$SANDBOX/prompt-home-second/memories"
ln -s "$SANDBOX/prompt-home-a/memories_extensions" "$SANDBOX/prompt-home-second/memories_extensions"
cat > "$SANDBOX/prompt-home-a/history.jsonl" <<EOF
{"session_id":"$PROMPT_RESUME_SESSION_ID","ts":1760000009,"text":"prompt primary work"}
EOF
cat > "$SANDBOX/prompt-home-a/sessions/$PROMPT_RESUME_REL" <<EOF
{"type":"session_meta","payload":{"id":"$PROMPT_RESUME_SESSION_ID","cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/prompt-home-a" \
SECOND_CODEX_HOME="$SANDBOX/prompt-home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/true" \
"$REPO_ROOT/second-codex" exec resume "$PROMPT_RESUME_SESSION_ID" >"$SANDBOX/prompt-resume.out" 2>&1
if grep -q "imported primary Codex session into second account runtime" "$SANDBOX/prompt-resume.out"; then
  echo "FAIL prompt text triggered primary session import"
  exit 1
fi
test ! -e "$SANDBOX/prompt-home-second/sessions/$PROMPT_RESUME_REL"

HISTORY_SYMLINK_SESSION_ID="00000000-0000-7000-8000-000000000010"
HISTORY_SYMLINK_REL="2026/05/03/rollout-2026-05-03T19-12-47-$HISTORY_SYMLINK_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-second/history.jsonl" <<EOF
{"session_id":"$HISTORY_SYMLINK_SESSION_ID","ts":1760000010,"text":"history symlink work"}
EOF
cat > "$SANDBOX/home-second/sessions/$HISTORY_SYMLINK_REL" <<EOF
{"type":"session_meta","payload":{"id":"$HISTORY_SYMLINK_SESSION_ID","cwd":"/tmp/project"}}
EOF
rm -f "$SANDBOX/home-a/history.jsonl"
touch "$SANDBOX/outside-history.jsonl"
ln -s "$SANDBOX/outside-history.jsonl" "$SANDBOX/home-a/history.jsonl"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "$HISTORY_SYMLINK_SESSION_ID" >"$SANDBOX/history-symlink.out" 2>&1; then
  echo "FAIL handoff followed a target history symlink"
  exit 1
fi
grep -q "refused to append through symlinked primary history" "$SANDBOX/history-symlink.out"
test ! -s "$SANDBOX/outside-history.jsonl"
test ! -e "$SANDBOX/home-a/sessions/$HISTORY_SYMLINK_REL"

rm -f "$SANDBOX/home-a/history.jsonl"
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  "$REPO_ROOT/second-codex" handoff "00000000-0000-7000-8000-000000000011" >"$SANDBOX/missing-source-session.out" 2>&1; then
  echo "FAIL missing source session unexpectedly succeeded"
  exit 1
fi
grep -q "could not find second account session file" "$SANDBOX/missing-source-session.out"
if grep -q "internal error" "$SANDBOX/missing-source-session.out"; then
  echo "FAIL missing source session was masked as internal error"
  exit 1
fi

echo "PASS handoff sandbox"
