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
SESSION_MODE="$(stat -f '%Lp' "$SANDBOX/home-a/sessions/$SESSION_REL" 2>/dev/null || stat -c '%a' "$SANDBOX/home-a/sessions/$SESSION_REL")"
test "$SESSION_MODE" = "600"
grep -Fq "\"session_id\":\"$SESSION_ID\"" "$SANDBOX/home-a/history.jsonl"
chmod 644 "$SANDBOX/home-a/sessions/$SESSION_REL"
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
"$REPO_ROOT/second-codex" handoff "$SESSION_ID" > "$SANDBOX/handoff-identical.out"
SESSION_MODE="$(stat -f '%Lp' "$SANDBOX/home-a/sessions/$SESSION_REL" 2>/dev/null || stat -c '%a' "$SANDBOX/home-a/sessions/$SESSION_REL")"
test "$SESSION_MODE" = "600"
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

RESUME_UNKNOWN_FLAG_SESSION_ID="00000000-0000-7000-8000-000000000099"
RESUME_UNKNOWN_FLAG_REL="2026/05/03/rollout-2026-05-03T19-21-47-$RESUME_UNKNOWN_FLAG_SESSION_ID.jsonl"
cat >> "$SANDBOX/home-a/history.jsonl" <<EOF
{"session_id":"$RESUME_UNKNOWN_FLAG_SESSION_ID","ts":1760000099,"text":"resume unknown flag primary work"}
EOF
cat > "$SANDBOX/home-a/sessions/$RESUME_UNKNOWN_FLAG_REL" <<EOF
{"type":"session_meta","payload":{"id":"$RESUME_UNKNOWN_FLAG_SESSION_ID","cwd":"/tmp/project"}}
EOF
if SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/false" \
  "$REPO_ROOT/second-codex" resume --unknown-future-flag my_value "$RESUME_UNKNOWN_FLAG_SESSION_ID" >"$SANDBOX/resume-unknown-flag.out" 2>&1; then
  echo "FAIL mock codex unexpectedly succeeded"
  exit 1
fi
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/resume-unknown-flag.out"
cmp -s "$SANDBOX/home-a/sessions/$RESUME_UNKNOWN_FLAG_REL" "$SANDBOX/home-second/sessions/$RESUME_UNKNOWN_FLAG_REL"

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
if ! grep -q "imported primary Codex session into second account runtime" "$SANDBOX/prompt-resume.out"; then
  echo "FAIL exec resume did not import primary session into second account runtime"
  exit 1
fi
cmp -s "$SANDBOX/prompt-home-a/sessions/$PROMPT_RESUME_REL" "$SANDBOX/prompt-home-second/sessions/$PROMPT_RESUME_REL"

EXEC_OPTION_RESUME_SESSION_ID="00000000-0000-7000-8000-000000000021"
EXEC_OPTION_RESUME_REL="2026/05/03/rollout-2026-05-03T19-22-47-$EXEC_OPTION_RESUME_SESSION_ID.jsonl"
cat >> "$SANDBOX/prompt-home-a/history.jsonl" <<EOF
{"session_id":"$EXEC_OPTION_RESUME_SESSION_ID","ts":1760000021,"text":"exec option resume primary work"}
EOF
cat > "$SANDBOX/prompt-home-a/sessions/$EXEC_OPTION_RESUME_REL" <<EOF
{"type":"session_meta","payload":{"id":"$EXEC_OPTION_RESUME_SESSION_ID","cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/prompt-home-a" \
SECOND_CODEX_HOME="$SANDBOX/prompt-home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/true" \
"$REPO_ROOT/second-codex" exec --model gpt-5.5 resume "$EXEC_OPTION_RESUME_SESSION_ID" >"$SANDBOX/exec-option-resume.out" 2>&1
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/exec-option-resume.out"
cmp -s "$SANDBOX/prompt-home-a/sessions/$EXEC_OPTION_RESUME_REL" "$SANDBOX/prompt-home-second/sessions/$EXEC_OPTION_RESUME_REL"

EXEC_ALIAS_RESUME_SESSION_ID="00000000-0000-7000-8000-000000000022"
EXEC_ALIAS_RESUME_REL="2026/05/03/rollout-2026-05-03T19-23-47-$EXEC_ALIAS_RESUME_SESSION_ID.jsonl"
cat >> "$SANDBOX/prompt-home-a/history.jsonl" <<EOF
{"session_id":"$EXEC_ALIAS_RESUME_SESSION_ID","ts":1760000022,"text":"exec alias resume primary work"}
EOF
cat > "$SANDBOX/prompt-home-a/sessions/$EXEC_ALIAS_RESUME_REL" <<EOF
{"type":"session_meta","payload":{"id":"$EXEC_ALIAS_RESUME_SESSION_ID","cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/prompt-home-a" \
SECOND_CODEX_HOME="$SANDBOX/prompt-home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/true" \
"$REPO_ROOT/second-codex" e resume "$EXEC_ALIAS_RESUME_SESSION_ID" >"$SANDBOX/exec-alias-resume.out" 2>&1
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/exec-alias-resume.out"
cmp -s "$SANDBOX/prompt-home-a/sessions/$EXEC_ALIAS_RESUME_REL" "$SANDBOX/prompt-home-second/sessions/$EXEC_ALIAS_RESUME_REL"

EXEC_JSON_RESUME_SESSION_ID="00000000-0000-7000-8000-000000000025"
EXEC_JSON_RESUME_REL="2026/05/03/rollout-2026-05-03T19-26-47-$EXEC_JSON_RESUME_SESSION_ID.jsonl"
cat >> "$SANDBOX/prompt-home-a/history.jsonl" <<EOF
{"session_id":"$EXEC_JSON_RESUME_SESSION_ID","ts":1760000025,"text":"exec json resume primary work"}
EOF
cat > "$SANDBOX/prompt-home-a/sessions/$EXEC_JSON_RESUME_REL" <<EOF
{"type":"session_meta","payload":{"id":"$EXEC_JSON_RESUME_SESSION_ID","cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/prompt-home-a" \
SECOND_CODEX_HOME="$SANDBOX/prompt-home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/true" \
"$REPO_ROOT/second-codex" exec resume --json "$EXEC_JSON_RESUME_SESSION_ID" >"$SANDBOX/exec-json-resume.out" 2>&1
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/exec-json-resume.out"
cmp -s "$SANDBOX/prompt-home-a/sessions/$EXEC_JSON_RESUME_REL" "$SANDBOX/prompt-home-second/sessions/$EXEC_JSON_RESUME_REL"

EXEC_OUTPUT_RESUME_SESSION_ID="00000000-0000-7000-8000-000000000026"
EXEC_OUTPUT_RESUME_REL="2026/05/03/rollout-2026-05-03T19-27-47-$EXEC_OUTPUT_RESUME_SESSION_ID.jsonl"
cat >> "$SANDBOX/prompt-home-a/history.jsonl" <<EOF
{"session_id":"$EXEC_OUTPUT_RESUME_SESSION_ID","ts":1760000026,"text":"exec output resume primary work"}
EOF
cat > "$SANDBOX/prompt-home-a/sessions/$EXEC_OUTPUT_RESUME_REL" <<EOF
{"type":"session_meta","payload":{"id":"$EXEC_OUTPUT_RESUME_SESSION_ID","cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/prompt-home-a" \
SECOND_CODEX_HOME="$SANDBOX/prompt-home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/true" \
"$REPO_ROOT/second-codex" exec resume -o "$SANDBOX/last-message.txt" "$EXEC_OUTPUT_RESUME_SESSION_ID" >"$SANDBOX/exec-output-resume.out" 2>&1
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/exec-output-resume.out"
cmp -s "$SANDBOX/prompt-home-a/sessions/$EXEC_OUTPUT_RESUME_REL" "$SANDBOX/prompt-home-second/sessions/$EXEC_OUTPUT_RESUME_REL"

FORK_SESSION_ID="00000000-0000-7000-8000-000000000023"
FORK_REL="2026/05/03/rollout-2026-05-03T19-24-47-$FORK_SESSION_ID.jsonl"
cat >> "$SANDBOX/prompt-home-a/history.jsonl" <<EOF
{"session_id":"$FORK_SESSION_ID","ts":1760000023,"text":"fork primary work"}
EOF
cat > "$SANDBOX/prompt-home-a/sessions/$FORK_REL" <<EOF
{"type":"session_meta","payload":{"id":"$FORK_SESSION_ID","cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/prompt-home-a" \
SECOND_CODEX_HOME="$SANDBOX/prompt-home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/true" \
"$REPO_ROOT/second-codex" fork "$FORK_SESSION_ID" >"$SANDBOX/fork.out" 2>&1
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/fork.out"
cmp -s "$SANDBOX/prompt-home-a/sessions/$FORK_REL" "$SANDBOX/prompt-home-second/sessions/$FORK_REL"

FORK_OPTION_SESSION_ID="00000000-0000-7000-8000-000000000024"
FORK_OPTION_REL="2026/05/03/rollout-2026-05-03T19-25-47-$FORK_OPTION_SESSION_ID.jsonl"
cat >> "$SANDBOX/prompt-home-a/history.jsonl" <<EOF
{"session_id":"$FORK_OPTION_SESSION_ID","ts":1760000024,"text":"fork option primary work"}
EOF
cat > "$SANDBOX/prompt-home-a/sessions/$FORK_OPTION_REL" <<EOF
{"type":"session_meta","payload":{"id":"$FORK_OPTION_SESSION_ID","cwd":"/tmp/project"}}
EOF
SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/prompt-home-a" \
SECOND_CODEX_HOME="$SANDBOX/prompt-home-second" \
SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
SECOND_CODEX_SWITCH_REAL_CODEX="/usr/bin/true" \
"$REPO_ROOT/second-codex" --model gpt-5.5 fork "$FORK_OPTION_SESSION_ID" >"$SANDBOX/fork-option.out" 2>&1
grep -q "imported primary Codex session into second account runtime" "$SANDBOX/fork-option.out"
cmp -s "$SANDBOX/prompt-home-a/sessions/$FORK_OPTION_REL" "$SANDBOX/prompt-home-second/sessions/$FORK_OPTION_REL"

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

# ---------------------------------------------------------------------------
# session-id --cwd at scale (issue #6 sub-bullet 3): pin that the
# rglob -> targeted-glob refactor finds the target session correctly
# even when the sessions tree contains ~200 unrelated rollouts spread
# across multiple YYYY/MM/DD subdirs. Pre-#6 used `sessions.rglob`
# which would have walked every file; the new code uses a targeted
# glob `*/*/*/rollout-*-<uuid>.jsonl` driven by `recent_rank` from
# history. Functional verification at scale; a loose 10s budget catches
# a regression to a quadratic algorithm but is not a tight perf bound.
# ---------------------------------------------------------------------------
# Nest the scale dir inside $SANDBOX rather than mktemp'ing a sibling:
# bash `trap ... EXIT` does not stack — installing a second EXIT trap
# here would silently clobber the line-6 trap and leak $SANDBOX on
# script exit. Putting scale data inside $SANDBOX lets the existing
# trap clean both with one rm -rf. (Panel review of PR #7, 2026-05-04.)
SCALE_SANDBOX="$SANDBOX/scale"
mkdir -p "$SCALE_SANDBOX"
SCALE_HOME="$SCALE_SANDBOX/home-second"
mkdir -p "$SCALE_HOME/sessions"
SCALE_TARGET_ID="019dee99-1006-7000-8000-deadbeefcafe"
SCALE_TARGET_CWD="/tmp/scale-project"
# Synthesize 200 unrelated sessions across multiple YYYY/MM/DD dirs.
python3 - "$SCALE_HOME" "$SCALE_TARGET_ID" "$SCALE_TARGET_CWD" <<'PY'
import json
import sys
import uuid
from pathlib import Path

home = Path(sys.argv[1])
target_id = sys.argv[2]
target_cwd = sys.argv[3]
sessions = home / "sessions"

# Spread 200 noise sessions across 5 different YYYY/MM/DD buckets so the
# targeted glob (`*/*/*/rollout-*-<uuid>.jsonl`) has to hit multiple
# directory paths. Pre-#6 rglob would have walked all of them.
buckets = [
    ("2024", "01", "15"),
    ("2024", "06", "20"),
    ("2025", "03", "10"),
    ("2025", "11", "05"),
    ("2026", "04", "30"),
]
for i in range(200):
    yy, mm, dd = buckets[i % len(buckets)]
    bucket = sessions / yy / mm / dd
    bucket.mkdir(parents=True, exist_ok=True)
    sid = str(uuid.uuid4())
    fp = bucket / f"rollout-{yy}-{mm}-{dd}T00-00-{i:02d}-{sid}.jsonl"
    fp.write_text(json.dumps({
        "type": "session_meta",
        "payload": {"id": sid, "cwd": f"/tmp/noise-{i}"},
    }) + "\n")

# The target session: cwd matches what we'll search for.
target_dir = sessions / "2026" / "05" / "04"
target_dir.mkdir(parents=True, exist_ok=True)
target_path = target_dir / f"rollout-2026-05-04T00-00-00-{target_id}.jsonl"
target_path.write_text(json.dumps({
    "type": "session_meta",
    "payload": {"id": target_id, "cwd": target_cwd},
}) + "\n")

# History ranks the target first (most recent).
(home / "history.jsonl").write_text(
    json.dumps({"session_id": target_id, "ts": 1777800000, "text": "target"}) + "\n"
)
PY

mkdir -p "$SANDBOX/scale-home-a"
SCALE_START=$(python3 -c 'import time; print(time.monotonic())')
SCALE_OUT=$(SECOND_CODEX_SWITCH_ROOT="$SANDBOX/scale-root" \
  CODEX_A_HOME="$SANDBOX/scale-home-a" \
  SECOND_CODEX_HOME="$SCALE_HOME" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/scale-shim" \
  "$REPO_ROOT/second-codex" session-id --second "$SCALE_TARGET_CWD" 2>&1)
SCALE_RC=$?
SCALE_END=$(python3 -c 'import time; print(time.monotonic())')
SCALE_ELAPSED=$(python3 -c "print($SCALE_END - $SCALE_START)")

if [[ "$SCALE_RC" -ne 0 ]]; then
  echo "FAIL session-id at scale exited rc=$SCALE_RC: $SCALE_OUT"
  exit 1
fi
if ! grep -Fxq "$SCALE_TARGET_ID" <<<"$SCALE_OUT"; then
  echo "FAIL session-id at scale returned wrong id: got '$SCALE_OUT', expected '$SCALE_TARGET_ID'"
  exit 1
fi
# Loose 10-second budget — a regression to rglob on a 200-file corpus
# should still complete in ~1s on modern hardware, so 10s catches an
# accidental quadratic algorithm but doesn't flake on slow CI.
SCALE_TOO_SLOW=$(python3 -c "print(1 if $SCALE_ELAPSED > 10 else 0)")
if [[ "$SCALE_TOO_SLOW" == "1" ]]; then
  echo "FAIL session-id at scale took ${SCALE_ELAPSED}s (>10s budget) — possible regression to walk-everything algorithm"
  exit 1
fi
echo "session-id finds target across 200 noise sessions in ${SCALE_ELAPSED}s PASSED"

# ---------------------------------------------------------------------------
# session-id symlink-safe cwd compare (Gemini-CA review of PR #7):
# Native Codex captures cwd via POSIX getcwd() so its rollouts store the
# physical path (/private/tmp/foo on macOS). If a caller invokes
# `second-codex session-id <symlinked-cwd>`, the pre-fix direct-equality
# compare would never match. Pin: passing a symlinked cwd that resolves
# to the rollout's recorded physical path returns the right session id.
# ---------------------------------------------------------------------------
SYMLINK_HOME="$SANDBOX/symlink/home-second"
mkdir -p "$SYMLINK_HOME/sessions/2026/05/04"
SYMLINK_TARGET_ID="019dee99-2007-7000-8000-cafebabefade"
# Create an actual symlink: $SANDBOX/symlink/link points at /private/<...>.
# The session is recorded under the realpath; we pass the symlinked path
# to session-id and assert it still finds the target.
SYMLINK_REAL_DIR="$SANDBOX/symlink/real-project"
mkdir -p "$SYMLINK_REAL_DIR"
SYMLINK_LINK_DIR="$SANDBOX/symlink/linked-project"
ln -s "$SYMLINK_REAL_DIR" "$SYMLINK_LINK_DIR"
SYMLINK_REAL_RESOLVED=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SYMLINK_LINK_DIR")
python3 - "$SYMLINK_HOME" "$SYMLINK_TARGET_ID" "$SYMLINK_REAL_RESOLVED" <<'PY'
import json
import sys
from pathlib import Path
home = Path(sys.argv[1])
target_id = sys.argv[2]
real_cwd = sys.argv[3]
target = home / "sessions/2026/05/04" / f"rollout-2026-05-04T00-00-00-{target_id}.jsonl"
target.write_text(json.dumps({
    "type": "session_meta",
    "payload": {"id": target_id, "cwd": real_cwd},
}) + "\n")
(home / "history.jsonl").write_text(
    json.dumps({"session_id": target_id, "ts": 1777800000, "text": "target"}) + "\n"
)
PY
SYMLINK_OUT=$(SECOND_CODEX_SWITCH_ROOT="$SANDBOX/symlink-root" \
  CODEX_A_HOME="$SANDBOX/symlink-home-a" \
  SECOND_CODEX_HOME="$SYMLINK_HOME" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/symlink-shim" \
  "$REPO_ROOT/second-codex" session-id --second "$SYMLINK_LINK_DIR" 2>&1)
SYMLINK_RC=$?
if [[ "$SYMLINK_RC" -ne 0 ]]; then
  echo "FAIL session-id symlink compare exited rc=$SYMLINK_RC: $SYMLINK_OUT"
  exit 1
fi
if ! grep -Fxq "$SYMLINK_TARGET_ID" <<<"$SYMLINK_OUT"; then
  echo "FAIL session-id symlink compare returned wrong id: got '$SYMLINK_OUT', expected '$SYMLINK_TARGET_ID'"
  exit 1
fi
echo "session-id resolves symlinked cwd against physical-path rollout PASSED"

# ---------------------------------------------------------------------------
# session-id _SESSION_ID_RE direct regex unit test (PR #7 round 2):
# Round-2 panel (Gemini [BUG], DeepSeek, Kimi) flagged the original
# glob-guard integration test below as vacuous: target_id is appended
# last to history.jsonl
# but the heredoc reads via `reversed(lines)` so target gets rank 0
# and is processed first; the inner `payload.get("id") != session_id`
# resilience also catches malformed entries silently. The integration
# test below is preserved as a happy-path regression guard, but the
# regex's actual drop-behavior is pinned here as a direct unit test.
#
# Extract the regex from the wrapper itself so a wrapper-side change
# updates this test automatically (no drift between source-of-truth
# and assertion).
# ---------------------------------------------------------------------------
WRAPPER_REGEX=$(awk -F'"' '/_SESSION_ID_RE = re.compile/{print $2; exit}' "$REPO_ROOT/second-codex")
if [[ -z "$WRAPPER_REGEX" ]]; then
  echo "FAIL could not extract _SESSION_ID_RE from $REPO_ROOT/second-codex"
  exit 1
fi
python3 - "$WRAPPER_REGEX" <<'PY'
import re
import sys
pat = re.compile(sys.argv[1])
# Valid UUIDs the regex MUST accept (v4 lower, v7 mixed, all-zeros).
for ok in [
    "019dee99-1006-7000-8000-deadbeefcafe",
    "01234567-89AB-CDEF-0123-456789ABCDEF",
    "00000000-0000-0000-0000-000000000000",
    "fedcba98-7654-3210-fedc-ba9876543210",
]:
    if not pat.match(ok):
        print(f"FAIL regex should accept {ok!r}")
        raise SystemExit(1)
# Malformed inputs the regex MUST reject. Covers shell-glob
# metacharacters (Greptile P2's exact concern), traversal attempts,
# truncations, length bloat, embedded whitespace, and newline/CR
# injection (history.jsonl could in theory carry CRLF on Windows-
# written files even though Codex itself doesn't).
for bad in [
    "*",
    "?-bogus",
    "[abc].not-a-uuid",
    "../../etc/passwd",
    "",
    "01234567",
    "01234567-89ab-cdef-0123-456789abcdefXX",
    "01234567 89ab cdef 0123 456789abcdef",
    "01234567-89ab-cdef-0123-456789abcdef\n",
    "01234567-89ab-cdef-0123-456789abcdef\r",
    "01234567-89ab-cdef-0123-456789abcde",     # one short in the last group
    "g1234567-89ab-cdef-0123-456789abcdef",    # non-hex char
    "{01234567-89ab-cdef-0123-456789abcdef}",  # brace-wrapped variant
    "0123456789abcdef0123456789abcdef",        # 32 hex, no hyphens (GLM round-3)
]:
    if pat.match(bad):
        print(f"FAIL regex should reject {bad!r}")
        raise SystemExit(1)
print("UUID regex unit test PASSED (regex extracted from wrapper)")
PY

# ---------------------------------------------------------------------------
# session-id glob-safety happy-path regression guard (Greptile P2):
# Functional non-regression guard — pins that a malformed history entry
# alongside a valid target does not break wrapper output. This does NOT
# directly verify the regex drops malformed entries (the unit test
# above does that); the algorithm's inner `payload.get("id") !=
# session_id` check would also resiliently reach the valid target even
# without the regex. Kept as a happy-path pin — if a future refactor
# changes ranking/iteration order such that malformed neighbors break
# the loop, this catches it.
# ---------------------------------------------------------------------------
GLOB_HOME="$SANDBOX/glob-guard/home-second"
mkdir -p "$GLOB_HOME/sessions/2026/05/04"
GLOB_TARGET_ID="019dee99-3008-7000-8000-feedfacec0de"
GLOB_TARGET_CWD="/tmp/glob-guard-project"
# A real session for the legitimate target id.
python3 - "$GLOB_HOME" "$GLOB_TARGET_ID" "$GLOB_TARGET_CWD" <<'PY'
import json
import sys
from pathlib import Path
home = Path(sys.argv[1])
target_id = sys.argv[2]
target_cwd = sys.argv[3]
target = home / "sessions/2026/05/04" / f"rollout-2026-05-04T00-00-00-{target_id}.jsonl"
target.write_text(json.dumps({
    "type": "session_meta",
    "payload": {"id": target_id, "cwd": target_cwd},
}) + "\n")
# Mix malformed entries among valid target in history.jsonl. Iteration
# order: tail_lines() yields forward, then reversed(lines) processes
# bottom-up. Writing target first then bogus entries below means
# reversed-iteration sees bogus FIRST in recent_rank. With the regex
# guard active, bogus entries are dropped before glob expansion. Even
# without the guard, the algorithm would still ultimately reach the
# valid target via the inner id-match check — this test is a happy-
# path regression pin for that resilience, not a direct regex pin.
malformed_ids = ["*", "?-bogus", "[abc].not-a-uuid", "../../etc/passwd"]
with (home / "history.jsonl").open("w") as f:
    f.write(json.dumps({"session_id": target_id, "ts": 1777800000, "text": "target"}) + "\n")
    for bogus in malformed_ids:
        f.write(json.dumps({"session_id": bogus, "ts": 1777800001, "text": "bogus"}) + "\n")
PY
GLOB_OUT=$(SECOND_CODEX_SWITCH_ROOT="$SANDBOX/glob-root" \
  CODEX_A_HOME="$SANDBOX/glob-home-a" \
  SECOND_CODEX_HOME="$GLOB_HOME" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/glob-shim" \
  "$REPO_ROOT/second-codex" session-id --second "$GLOB_TARGET_CWD" 2>&1)
GLOB_RC=$?
if [[ "$GLOB_RC" -ne 0 ]]; then
  echo "FAIL session-id glob-guard exited rc=$GLOB_RC: $GLOB_OUT"
  exit 1
fi
if ! grep -Fxq "$GLOB_TARGET_ID" <<<"$GLOB_OUT"; then
  echo "FAIL session-id glob-guard returned wrong id: got '$GLOB_OUT', expected '$GLOB_TARGET_ID'"
  exit 1
fi
echo "session-id finds valid target despite malformed history neighbors PASSED"

echo "PASS handoff sandbox"
