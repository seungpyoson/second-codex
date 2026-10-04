#!/usr/bin/env python3
"""Native subscription CLI entrypoints. No credential copying or gateway routing."""

import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import tomllib


class ProfileError(Exception):
    pass


SHARED_NAMES = {
    "AGENTS.md", "CLAUDE.md", "config.toml", "settings.json", "skills",
    "rules", "commands", "agents", "hooks.json", "plugins",
}
BLOCKED_ENV = {
    "codex": {
        "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL",
        "OPENAI_API_BASE", "CODEX_CHATGPT_BASE_URL", "CHATGPT_BASE_URL",
    },
    "claude": {
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
        "CLAUDE_CODE_SIMPLE", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    },
}
CODEX_AUTH_CONFIG = {
    "model_provider", "model_providers", "forced_login_method",
    "cli_auth_credentials_store", "openai_base_url", "chatgpt_base_url", "profile", "profiles",
}
NATIVE_SETTINGS = {"config.toml", "settings.json"}


def require(condition, message):
    if not condition:
        raise ProfileError(message)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        raise ProfileError(f"Cannot read valid JSON from {path}") from None


def absolute_path(value):
    require(isinstance(value, str) and Path(value).is_absolute(), "Paths must be absolute")
    return Path(value)


def validate_manifest(config, selected=None):
    require(config["version"] == 1, "Unsupported named-account manifest version")
    homes = set()
    require(bool(config["accounts"]), "accounts is required")
    absolute_path(config["install_root"])
    absolute_path(config["bin_dir"])
    for name, account in config["accounts"].items():
        require(re.fullmatch(r"(codex|claude)-[a-z0-9][a-z0-9._-]*", name), "Invalid command name")
        require(account["provider"] == name.split("-", 1)[0], f"{name}: provider mismatch")
        home = absolute_path(account["home"]).resolve()
        require(home not in homes, "Each command must have a distinct native home")
        homes.add(home)
        executable = absolute_path(account["executable"])
        links = account["shared"]
        required = {"AGENTS.md", "config.toml"} if account["provider"] == "codex" else {
            "AGENTS.md", "CLAUDE.md", "settings.json",
        }
        require(required <= links.keys(), f"{name}: missing required shared configuration")
        require(links.keys() <= SHARED_NAMES, "Credentials/runtime paths cannot be shared")
        if selected is not None and name != selected:
            continue
        require(executable.is_file() and os.access(executable, os.X_OK), f"Missing CLI: {executable}")
        for target in links.values():
            require(absolute_path(target).exists(), f"Missing shared source: {target}")


def verify_shared(account):
    home = Path(account["home"])
    require(home.is_dir(), f"Missing profile directory: {home}")
    for name, source in account["shared"].items():
        target, path = Path(source), home / name
        # The legacy second-codex projector may replace a file link with an
        # identical current copy. Accept its bytes, never a stale policy/config.
        if path.resolve() == target.resolve():
            require(path.exists(), f"Missing shared configuration: {path}")
        elif path.is_file() and target.is_file():
            # Native tools atomically replace their settings files (for example,
            # project trust and UI choices). Model defaults remain authoritative
            # in the shared source and are passed explicitly at launch.
            if name not in NATIVE_SETTINGS:
                require(path.read_bytes() == target.read_bytes(), f"Stale configuration: {path}; repair its shared reference")
        else:
            raise ProfileError(f"Shared configuration is not linked to its source: {path}")


def prepare_arguments(provider, args):
    blocked = {"--with-api-key", "--with-access-token", "--oss", "--local-provider", "--remote", "--profile", "-p"} if provider == "codex" else {
        "--console", "--bare", "--settings", "--setting-sources",
    }
    for i, arg in enumerate(args):
        if arg == "--":
            break
        flag = arg.split("=", 1)[0]
        require(flag not in blocked, f"{flag} conflicts with a named subscription profile")
        if provider == "codex":
            value = None
            if arg in {"-c", "--config"}:
                require(i + 1 < len(args), f"{arg} requires a value")
                value = args[i + 1]
            elif arg.startswith("--config="):
                value = arg.split("=", 1)[1]
            elif arg.startswith("-c") and len(arg) > 2:
                value = arg[2:]
            require(not (arg.startswith("-p") and len(arg) > 2), "Config profiles cannot override named account configuration")
            if value is not None:
                try:
                    keys = tomllib.loads(value.split("=", 1)[0] + "=0")
                except tomllib.TOMLDecodeError:
                    raise ProfileError("Invalid configuration override key") from None
                require(not CODEX_AUTH_CONFIG.intersection(keys), "Account/provider configuration cannot be overridden")
    if provider == "codex":
        return ["--no-daemon", "-c", 'forced_login_method="chatgpt"',
                "-c", 'cli_auth_credentials_store="file"', "-c", 'model_provider="openai"', *args]
    return args


def model_arguments(account):
    provider = account["provider"]
    name = "config.toml" if provider == "codex" else "settings.json"
    source, native = Path(account["shared"][name]), Path(account["home"]) / name
    parsed = []
    for path in (source, native):
        if provider == "codex":
            try:
                settings = tomllib.loads(path.read_text())
            except (OSError, ValueError):
                raise ProfileError(f"Invalid native settings: {path}") from None
            require(not any(key in settings for key in ("profile", "profiles", "openai_base_url", "chatgpt_base_url")),
                    "Codex account profiles cannot set alternate profiles or service URLs")
            require(settings.get("model_provider", "openai") == "openai"
                    and "openai" not in settings.get("model_providers", {}), "Codex must use the built-in OpenAI provider")
        else:
            settings = read_json(path)
            conflicts = set(settings.get("env", {})) & (BLOCKED_ENV["claude"] | {"CLAUDE_CONFIG_DIR"})
            require(not conflicts and "apiKeyHelper" not in settings
                    and settings.get("forceLoginMethod", "claudeai") == "claudeai",
                    "Claude settings conflict with native subscription authentication")
        parsed.append(settings)
    settings = parsed[0]
    require(isinstance(settings["model"], str) and bool(settings["model"]), "An authoritative model is required")
    if provider == "codex":
        # Config overrides are repeatable; --model is not. Native --model and
        # later user config overrides therefore keep their normal precedence.
        return ["-c", "model=" + json.dumps(settings["model"]), "-c", "model_reasoning_effort=" + json.dumps(settings["model_reasoning_effort"])]
    # Claude accepts repeated native model/effort options. Leading defaults keep
    # their CLI precedence over ambient model variables; explicit later flags
    # retain the native last-value behavior. Effort "max" is a CLI-only value.
    defaults = ["--model", settings["model"]]
    if "effortLevel" in settings:
        defaults += ["--effort", settings["effortLevel"]]
    return defaults


def native_environment(provider, home, command, ambient):
    conflicts = sorted(key for key in BLOCKED_ENV[provider] if ambient.get(key))
    require(not conflicts, "Unset conflicting authentication/provider variables: " + ", ".join(conflicts))
    env = dict(ambient)
    env["CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR"] = home
    env["NAMED_AGENT_ACCOUNT"] = command
    if provider == "codex":
        env["CODEX_ACCOUNT_SLOT"] = command.removeprefix("codex-")
        env.pop("SECOND_CODEX_ACTIVE_ACCOUNT", None)
    return env


def authenticated_identity(account, env):
    if account["provider"] == "codex":
        auth_path = Path(account["home"]) / "auth.json"
        if not auth_path.exists():
            return None
        auth = read_json(auth_path)
        require(not auth.get("OPENAI_API_KEY"), "This profile contains API-key authentication")
        try:
            tokens = auth["tokens"]
            require(bool(tokens["refresh_token"]), "Missing subscription refresh token")
            part = tokens["id_token"].split(".")[1]
            claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
            return claims["email"]
        except (KeyError, IndexError, TypeError, ValueError):
            raise ProfileError("Cannot identify the saved Codex subscription; use native login") from None
    result = subprocess.run([account["executable"], "auth", "status"], env=env,
                            capture_output=True, text=True, timeout=30)
    try:
        status = json.loads(result.stdout)
        if status["loggedIn"] is False:
            return None
        require(result.returncode == 0 and status["authMethod"] == "claude.ai"
                and status["apiProvider"] == "firstParty", "Claude profile is not using native subscription authentication")
        return status["email"]
    except (KeyError, TypeError, ValueError):
        raise ProfileError("Cannot verify native Claude authentication status") from None


def authentication_action(provider, args):
    """Recognize native auth subcommands after supported leading CLI options."""
    valued = {"--model", "--effort", "--agent"}
    if provider == "codex":
        valued |= {"-m", "-c", "--config", "-C", "--cd", "-s", "--sandbox",
                   "-a", "--ask-for-approval", "--enable", "--disable", "--add-dir"}
    i = 0
    while i < len(args) and args[i].startswith("-"):
        flag = args[i].split("=", 1)[0]
        if flag not in valued:
            # Unknown or variadic options can consume following tokens. Never
            # mistake an option value for a native authentication command.
            return False, False
        i += 1 if "=" in args[i] else 2
    tail = args[i:]
    if provider == "codex":
        return bool(tail) and tail[0] in {"login", "logout"}, tail == ["login", "status"]
    return bool(tail) and tail[0] == "auth", tail == ["auth", "status"]


def launch(config, command, args):
    require(command in config["accounts"], "Unknown named account")
    validate_manifest(config, selected=command)
    account = config["accounts"][command]
    verify_shared(account)
    provider = account["provider"]
    env = native_environment(provider, account["home"], command, os.environ)
    native_args = model_arguments(account) + prepare_arguments(provider, args)
    is_help = args in (["--help"], ["-h"], ["--version"], ["-V"])
    is_auth, is_status = authentication_action(provider, args)
    # Native login/logout must remain available to connect or correct an account.
    # Status and ordinary launches still verify the account label.
    if not is_help and (not is_auth or is_status):
        identity = authenticated_identity(account, env)
        login = "login" if provider == "codex" else "auth login --claudeai"
        require(identity is not None, f"Not signed in. Run: {command} {login}")
        require(isinstance(identity, str) and identity.rsplit("@", 1)[0].lower() == command.split("-", 1)[1],
                f"Saved login does not match {command}; use its native logout/login commands")
    os.execve(account["executable"], [account["executable"], *native_args], env)


def install(manifest_path):
    config = read_json(manifest_path)
    validate_manifest(config)
    root = Path(config["install_root"])
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (root / ".install.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        install_locked(config)


def install_locked(config):
    root, bin_dir = Path(config["install_root"]), Path(config["bin_dir"])
    script = root / "named_accounts.py"
    installed_manifest = root / "accounts.json"
    source = Path(__file__).resolve()
    replacements, links = [], []
    batch = str(time.time_ns())
    prior = read_json(installed_manifest) if installed_manifest.exists() else None
    if prior is not None:
        require(prior["accounts"].keys() <= config["accounts"].keys(), "Account removal requires explicitly uninstalling its command first")
    for command, account in config["accounts"].items():
        home = Path(account["home"])
        require(not home.is_symlink(), f"Native home must not be a symlink: {home}")
        for name, target in account["shared"].items():
            path = home / name
            if path.resolve() == Path(target).resolve():
                continue
            if path.exists() or path.is_symlink():
                if (prior is not None and command in prior["accounts"] and name in NATIVE_SETTINGS
                        and path.is_file() and not path.is_symlink()
                        and prior["accounts"][command]["home"] == account["home"]):
                    continue
                approved = account["replace_sha256"].get(name)
                approved_dir = account["replace_directory_identity"].get(name)
                is_approved_file = (path.is_file() and not path.is_symlink() and approved is not None
                                    and hashlib.sha256(path.read_bytes()).hexdigest() == approved)
                is_approved_dir = (path.is_dir() and not path.is_symlink() and approved_dir is not None
                                   and [path.stat().st_dev, path.stat().st_ino] == approved_dir)
                previous = prior["accounts"].get(command) if prior is not None else None
                is_managed_link = (path.is_symlink() and previous is not None
                                   and previous["home"] == account["home"]
                                   and name in previous["shared"]
                                   and os.readlink(path) == str(Path(previous["shared"][name])))
                require(is_approved_file or is_approved_dir or is_managed_link,
                        f"Conflicting profile path: {path}")
                backup = root / "preserved" / batch / command / name
                require(not backup.exists(), f"Backup already exists: {backup}")
                replacements.append((path, backup))
            links.append((path, Path(target)))
        entry = bin_dir / command
        require(not (entry.exists() or entry.is_symlink()) or (entry.is_symlink() and entry.resolve() == script.resolve()),
                f"Conflicting command: {entry}")
    # Validate every conflict before touching any profile. Existing credentials
    # and runtime paths are never part of the operation.
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    created, moved, metadata = [], [], []
    try:
        for account in config["accounts"].values():
            Path(account["home"]).mkdir(mode=0o700, parents=True, exist_ok=True)
        for path, backup in replacements:
            backup.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.rename(backup)
            moved.append((path, backup))
        for path, target in links:
            path.symlink_to(target, target_is_directory=target.is_dir())
            created.append(path)
        for command in config["accounts"]:
            entry = bin_dir / command
            if not entry.is_symlink():
                entry.symlink_to(script)
                created.append(entry)
        require(not any(c.isspace() for c in sys.executable), "Python executable path cannot contain whitespace")
        script_bytes = ("#!" + sys.executable + "\n").encode() + source.read_bytes().split(b"\n", 1)[1]
        for target, content, mode in [(script, script_bytes, 0o700),
                                      (installed_manifest, (json.dumps(config, indent=2) + "\n").encode(), 0o600)]:
            old = (target.read_bytes(), target.stat().st_mode & 0o777) if target.exists() else None
            metadata.append((target, old))
            atomic_write(target, content, mode)
    except BaseException as failure:
        cleanup = []
        for target, old in reversed(metadata):
            try:
                if old is None:
                    target.unlink(missing_ok=True)
                else:
                    atomic_write(target, old[0], old[1])
            except OSError as error:
                cleanup.append(error)
        for path in reversed(created):
            try:
                path.unlink()
            except OSError as error:
                cleanup.append(error)
        for path, backup in reversed(moved):
            try:
                backup.rename(path)
            except OSError as error:
                cleanup.append(error)
        if cleanup:
            raise BaseExceptionGroup("Installation failed; rollback also encountered errors", [failure, *cleanup])
        raise
    print(json.dumps({"installed": list(config["accounts"]), "install_root": str(root),
                      "preserved": [str(backup) for _, backup in moved]}))


def atomic_write(target, content, mode):
    fd, temporary_name = tempfile.mkstemp(prefix=target.name + ".install-", dir=target.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        temporary.chmod(mode)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    name = Path(sys.argv[0]).name
    try:
        if name == "named_accounts.py" and len(sys.argv) == 3 and sys.argv[1] == "install":
            install(Path(sys.argv[2]))
        else:
            root = Path(__file__).resolve().parent
            with (root / ".install.lock").open("r") as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                config = read_json(root / "accounts.json")
                launch(config, name, sys.argv[1:])
    except (ProfileError, KeyError, OSError, subprocess.TimeoutExpired) as error:
        print(f"named account: {error}", file=sys.stderr)
        raise SystemExit(78)


if __name__ == "__main__":
    main()
