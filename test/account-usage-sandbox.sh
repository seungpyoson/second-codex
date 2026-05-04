#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-account-usage-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home-a/sessions/2026/05/04" "$SANDBOX/home-second/sessions/2026/05/04"

SESSION_ID="33333333-3333-7333-8333-333333333333"
SESSION_REL="2026/05/04/rollout-2026-05-04T12-00-00-$SESSION_ID.jsonl"
cat > "$SANDBOX/home-second/history.jsonl" <<EOF
{"session_id":"$SESSION_ID","ts":1770000000}
EOF
cat > "$SANDBOX/home-second/sessions/$SESSION_REL" <<EOF
{"type":"session_meta","payload":{"id":"$SESSION_ID","cwd":"/tmp/project"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":3,"reasoning_output_tokens":2,"total_tokens":13},"last_token_usage":{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":7},"model_context_window":1000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1770000300},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1770000600},"credits":null,"plan_type":"pro","rate_limit_reached_type":null}}}
EOF

CODEX_ACCOUNT_SLOT=second \
CODEX_HOME="$SANDBOX/home-second" \
"$REPO_ROOT/second-codex" account > "$SANDBOX/account.out"
grep -Fxq "account_slot=second" "$SANDBOX/account.out"
grep -Fxq "codex_home=$SANDBOX/home-second" "$SANDBOX/account.out"

SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
CODEX_A_HOME="$SANDBOX/home-a" \
SECOND_CODEX_HOME="$SANDBOX/home-second" \
"$REPO_ROOT/second-codex" usage --second > "$SANDBOX/usage.out"
grep -Fxq "account_slot=second" "$SANDBOX/usage.out"
grep -Fxq "session_id=$SESSION_ID" "$SANDBOX/usage.out"
grep -Fxq "total_tokens=13" "$SANDBOX/usage.out"
grep -Fxq "last_total_tokens=7" "$SANDBOX/usage.out"
grep -Fxq "primary_used_percent=12.5" "$SANDBOX/usage.out"
grep -Fxq "secondary_used_percent=3.0" "$SANDBOX/usage.out"
grep -Fxq "plan_type=pro" "$SANDBOX/usage.out"

echo "PASS account usage sandbox"
