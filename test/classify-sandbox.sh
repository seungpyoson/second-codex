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
assert_blocked flag-signout --signout chat
assert_blocked flag-reconnect --reconnect chat
assert_blocked flag-sign-out --sign-out chat
assert_blocked separator-login -- login
assert_blocked separator-logout -- logout
assert_blocked separator-mcp-oauth -- mcp oauth
assert_blocked exec-flag-login exec --login=foo prompt
assert_blocked exec-flag-auth-token exec --auth-token=xyz hi
assert_blocked resume-flag-login resume --login=foo 00000000-0000-7000-8000-000000000099
assert_blocked chat-flag-auth-token chat --auth-token=h say hi
assert_blocked login-status-auth-token login status --auth-token=abc
assert_blocked login-status-login-flag login status --login=foo
assert_blocked mcp-add-flag-login mcp add --login=user server
assert_blocked mcp-add-auth-token mcp add --auth-token=abc server
assert_blocked plugin-add-flag-oauth plugin add --oauth=foo thing
assert_blocked plugin-install-reauth plugin install --reauth foo
assert_blocked plugin-install-signout plugin install --signout foo
assert_blocked reconnect-command reconnect
assert_blocked authenticate-command authenticate
assert_blocked authorize-command authorize

assert_second exec-login-prompt exec please write a login form
assert_second exec-auth-token-prompt exec rotate the auth token
assert_second exec-mcp-prompt exec how does mcp work
assert_second exec-update-prompt exec update the changelog
assert_second bare-update-prompt help me update the plugin config
assert_second max-tokens-flag --max-tokens=500 exec hi
assert_second token-budget-flag --token-budget=100 chat
assert_second no-login-flag --no-login chat
assert_second auth-mode-flag --auth-mode=passive chat
assert_second refresh-cache-flag --refresh-cache=1 exec hi
assert_second remote-auth-token-env --remote-auth-token-env MY_VAR exec hi
assert_second oss-prompt --oss write mcp docs
assert_second search-prompt --search help me update plugin config
assert_second no-alt-screen-prompt --no-alt-screen rotate auth token

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
