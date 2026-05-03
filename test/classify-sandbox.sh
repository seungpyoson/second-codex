#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/second-codex-classify-sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home-a" "$SANDBOX/home-second"
cat > "$SANDBOX/home-a/config.toml" <<'TOML'
model = "gpt-5.5"
TOML
mkdir -p "$SANDBOX/home-a/memories" "$SANDBOX/home-a/memories_extensions"
ln -s "$SANDBOX/home-a/memories" "$SANDBOX/home-second/memories"
ln -s "$SANDBOX/home-a/memories_extensions" "$SANDBOX/home-second/memories_extensions"

MOCK_CODEX="$SANDBOX/mock-codex"
cat > "$MOCK_CODEX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'home=%s args=%s\n' "${CODEX_HOME:?missing CODEX_HOME}" "$*" >> "${SECOND_CODEX_TEST_LOG:?missing SECOND_CODEX_TEST_LOG}"
SH
chmod 700 "$MOCK_CODEX"

run_wrapper() {
  SECOND_CODEX_SWITCH_ROOT="$SANDBOX/root" \
  CODEX_A_HOME="$SANDBOX/home-a" \
  SECOND_CODEX_HOME="$SANDBOX/home-second" \
  SECOND_CODEX_SHIM_DIR="$SANDBOX/shim" \
  SECOND_CODEX_SWITCH_REAL_CODEX="$MOCK_CODEX" \
  SECOND_CODEX_TEST_LOG="$SANDBOX/codex.log" \
  "$REPO_ROOT/second-codex" "$@"
}

assert_grep() {
  local pattern="$1"
  local file="$2"
  if ! grep -q "$pattern" "$file"; then
    echo "FAIL missing pattern '$pattern' in $file" >&2
    exit 1
  fi
}

assert_missing_file() {
  local file="$1"
  if [[ -e "$file" ]]; then
    echo "FAIL unexpected file exists: $file" >&2
    exit 1
  fi
}

assert_blocked() {
  local name="$1"
  shift
  if run_wrapper "$@" >"$SANDBOX/$name.out" 2>&1; then
    echo "FAIL $* was not blocked"
    exit 1
  fi
  assert_grep "refused this account/auth command" "$SANDBOX/$name.out"
}

assert_rerouted() {
  local name="$1"
  shift
  run_wrapper "$@" >"$SANDBOX/$name.out" 2>&1
  assert_grep "rerouting environment/config change" "$SANDBOX/$name.out"
  assert_grep "home=$SANDBOX/home-a args=$*" "$SANDBOX/codex.log"
}

assert_second() {
  local name="$1"
  shift
  run_wrapper "$@" >"$SANDBOX/$name.out" 2>&1
  assert_grep "home=$SANDBOX/home-second args=$*" "$SANDBOX/codex.log"
}

if run_wrapper login >"$SANDBOX/login.out" 2>&1; then
  echo "FAIL login was not blocked"
  exit 1
fi
assert_grep "refused this account/auth command" "$SANDBOX/login.out"
assert_missing_file "$SANDBOX/codex.log"

assert_blocked unknown-flag-login --unknown-future-flag value login
assert_blocked mcp-profile-oauth mcp -p default oauth
assert_blocked mcp-separator-oauth mcp -- oauth
assert_blocked plugin-marketplace-login plugin marketplace login
assert_blocked skill-marketplace-login skill marketplace login
assert_blocked app-marketplace-login app marketplace login
assert_blocked features-login features login
assert_blocked upgrade upgrade
assert_blocked flag-login --login=user@example.com chat
assert_blocked flag-auth-token --auth-token=abcdef chat
assert_blocked flag-oauth --oauth-redirect=http://example.test chat

assert_second exec-login-prompt exec please write a login form
assert_second exec-auth-token-prompt exec rotate the auth token
assert_second exec-mcp-prompt exec how does mcp work
assert_second exec-update-prompt exec update the changelog
assert_second bare-update-prompt help me update the plugin config
assert_second separator-prompt -- login

run_wrapper login status
assert_grep "home=$SANDBOX/home-second args=login status" "$SANDBOX/codex.log"

run_wrapper --config=model=gpt-5.5 mcp add parser-test -- /usr/bin/true >"$SANDBOX/reroute.out" 2>&1
assert_grep "rerouting environment/config change" "$SANDBOX/reroute.out"
assert_grep "home=$SANDBOX/home-a args=--config=model=gpt-5.5 mcp add parser-test -- /usr/bin/true" "$SANDBOX/codex.log"

run_wrapper --enable goals features enable another-feature >"$SANDBOX/features.out" 2>&1
assert_grep "rerouting environment/config change" "$SANDBOX/features.out"
assert_grep "home=$SANDBOX/home-a args=--enable goals features enable another-feature" "$SANDBOX/codex.log"

assert_rerouted mcp-config mcp config
assert_rerouted plugin-marketplace-add plugin marketplace add sample
assert_rerouted plugin-marketplace-upgrade plugin marketplace upgrade sample
assert_rerouted skill-install skill install sample
assert_rerouted features-enable features enable direct-feature
assert_rerouted trust trust

if run_wrapper plugin login >"$SANDBOX/plugin-login.out" 2>&1; then
  echo "FAIL plugin login was not blocked"
  exit 1
fi
assert_grep "refused this account/auth command" "$SANDBOX/plugin-login.out"
assert_blocked mcp-oauth mcp oauth
assert_blocked plugin-auth plugin auth
assert_blocked skill-login skill login
assert_blocked app-oauth app oauth

echo "PASS classify sandbox"
