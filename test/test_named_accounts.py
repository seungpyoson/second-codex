"""Exercise installed commands in separate processes using synthetic CLI/auth fixtures."""

import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "lib" / "named_accounts.py"
SPEC = importlib.util.spec_from_file_location("named_accounts", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
NAMES = ("seungpyoson", "spson.engineering", "sp.openclaw", "soongikwon")


class InstalledAccounts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="named-accounts-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {key: value for key, value in os.environ.items()
                    if key not in set.union(*MODULE.BLOCKED_ENV.values())}
        shared = self.root / "shared"
        shared.mkdir()
        for name, content in {"AGENTS.md": "canonical policy\n", "CLAUDE.md": "@AGENTS.md\n",
                              "config.toml": 'model="configured-model"\nmodel_reasoning_effort="max"\n',
                              "settings.json": '{"model":"configured-claude"}\n'}.items():
            (shared / name).write_text(content)
        self.config = {"version": 1, "install_root": str(self.root / "installed"),
                       "bin_dir": str(self.root / "bin"), "accounts": {}}
        for provider in ("codex", "claude"):
            exe = self.root / ("native-" + provider)
            exe.write_text("#!/usr/bin/env python3\nimport json,os,pathlib,sys\n"
                           + f"home=pathlib.Path(os.environ[{('CODEX_HOME' if provider == 'codex' else 'CLAUDE_CONFIG_DIR')!r}])\n"
                           + "if sys.argv[1:]==['auth','status']:\n"
                           + " print(json.dumps({'loggedIn':True,'authMethod':'claude.ai','apiProvider':'firstParty','email':home.name+'@example.invalid'}))\n"
                           + "else:\n print(json.dumps({'args':sys.argv[1:],'home':str(home),'account':os.environ['NAMED_AGENT_ACCOUNT']}))\n"
                           + " if (home/'native-exit').exists(): sys.exit(int((home/'native-exit').read_text()))\n")
            exe.chmod(0o700)
            for identity in NAMES:
                home = self.root / "profiles" / provider / identity
                home.mkdir(parents=True)
                if provider == "codex":
                    payload = base64.urlsafe_b64encode(json.dumps({"email": identity + "@example.invalid"}).encode()).decode().rstrip("=")
                    (home / "auth.json").write_text(json.dumps({"tokens": {"refresh_token": "synthetic-fixture", "id_token": "fixture." + payload + ".fixture"}}))
                names = ["AGENTS.md", "config.toml"] if provider == "codex" else ["AGENTS.md", "CLAUDE.md", "settings.json"]
                self.config["accounts"][provider + "-" + identity] = {
                    "provider": provider, "home": str(home), "executable": str(exe),
                    "shared": {name: str(shared / name) for name in names}, "replace_sha256": {},
                    "replace_directory_identity": {},
                }
        self.manifest = self.root / "input.json"
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps(self.config))

    def install(self):
        return subprocess.run([sys.executable, str(SOURCE), "install", str(self.manifest)], env=self.env,
                              capture_output=True, text=True)

    def run_account(self, name, *args, env=None):
        return subprocess.run([str(self.root / "bin" / name), *args], env=self.env if env is None else env,
                              capture_output=True, text=True)

    def test_all_eight_entrypoints_select_distinct_homes_and_preserve_arguments(self):
        self.assertEqual(self.install().returncode, 0)
        for command, account in self.config["accounts"].items():
            with self.subTest(command=command):
                args = ["exec", "literal spaces; $(never-run) 'quotes' "] if command.startswith("codex-") else ["-p", "literal spaces; $(never-run) 'quotes' "]
                result = self.run_account(command, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                got = json.loads(result.stdout)
                self.assertEqual(got["home"], account["home"])
                self.assertEqual(got["account"], command)
                self.assertEqual(got["args"][-len(args):], args)
                if command.startswith("codex-"):
                    self.assertIn('forced_login_method="chatgpt"', got["args"])

    def test_missing_login_and_wrong_identity_never_invoke_native_inference(self):
        self.assertEqual(self.install().returncode, 0)
        command = "codex-seungpyoson"
        path = Path(self.config["accounts"][command]["home"]) / "auth.json"
        other = Path(self.config["accounts"]["codex-soongikwon"]["home"]) / "auth.json"
        path.write_bytes(other.read_bytes())
        result = self.run_account(command, "exec", "hello")
        self.assertEqual(result.returncode, 78)
        self.assertIn("does not match", result.stderr)
        self.assertEqual(result.stdout, "")
        path.unlink()
        result = self.run_account(command, "exec", "hello")
        self.assertEqual(result.returncode, 78)
        self.assertIn("Not signed in", result.stderr)
        self.assertEqual(self.run_account(command, "login", "--device-auth").returncode, 0)
        self.assertEqual(self.run_account(command, "-c", 'model="explicit-model"', "login", "--device-auth").returncode, 0)

    def test_option_like_prompt_after_separator_is_preserved(self):
        self.assertEqual(self.install().returncode, 0)
        result = self.run_account("codex-seungpyoson", "exec", "--", "-print this literally")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["args"][-1], "-print this literally")

    def test_billing_overrides_rejected_without_exposing_values(self):
        self.assertEqual(self.install().returncode, 0)
        cases = [("codex-seungpyoson", ["login", "--with-api-key"]),
                 ("codex-seungpyoson", ["-c", '"model_provider"="other"', "exec", "hi"]),
                 ("codex-seungpyoson", ["--config=model_providers.openai.base_url=bad", "exec", "hi"]),
                 ("codex-seungpyoson", ["-c", 'profile="alternate"', "exec", "hi"]),
                 ("codex-seungpyoson", ["-c", 'profiles.alt.model_provider="other"', "exec", "hi"]),
                 ("claude-sp.openclaw", ["auth", "login", "--console"]),
                 ("claude-sp.openclaw", ["--settings", "{}", "-p", "hi"])]
        for command, args in cases:
            result = self.run_account(command, *args)
            self.assertEqual(result.returncode, 78, result.stdout)
        for command, variable in [("codex-seungpyoson", "OPENAI_API_KEY"), ("claude-sp.openclaw", "ANTHROPIC_API_KEY")]:
            result = self.run_account(command, "--version", env={**self.env, variable: "DO-NOT-PRINT-ME"})
            self.assertEqual(result.returncode, 78)
            self.assertIn(variable, result.stderr)
            self.assertNotIn("DO-NOT-PRINT-ME", result.stderr + result.stdout)

    def test_conflicting_entrypoint_is_detected_before_any_profile_mutation(self):
        bindir = self.root / "bin"
        bindir.mkdir()
        (bindir / "claude-soongikwon").write_text("existing user command")
        result = self.install()
        self.assertEqual(result.returncode, 78)
        self.assertEqual((bindir / "claude-soongikwon").read_text(), "existing user command")
        self.assertFalse((Path(self.config["accounts"]["codex-seungpyoson"]["home"]) / "AGENTS.md").exists())

    def test_identical_homes_rejected(self):
        self.config["accounts"]["codex-soongikwon"]["home"] = self.config["accounts"]["codex-seungpyoson"]["home"]
        self.save()
        self.assertEqual(self.install().returncode, 78)
        self.assertFalse((self.root / "bin").exists())

    def test_symlinked_home_rejected(self):
        account = self.config["accounts"]["codex-seungpyoson"]
        home = Path(account["home"])
        moved = self.root / "real-home"
        home.rename(moved)
        home.symlink_to(moved)
        self.assertEqual(self.install().returncode, 78)
        self.assertFalse((self.root / "bin").exists())

    def test_file_approval_cannot_replace_changed_content(self):
        account = self.config["accounts"]["codex-seungpyoson"]
        path = Path(account["home"]) / "AGENTS.md"
        path.write_bytes(b"new unapproved contents")
        account["replace_sha256"]["AGENTS.md"] = hashlib.sha256(b"old approved contents").hexdigest()
        self.save()
        self.assertEqual(self.install().returncode, 78)
        self.assertEqual(path.read_bytes(), b"new unapproved contents")

    def test_concurrent_installer_is_rejected_before_profile_mutation(self):
        root = Path(self.config["install_root"])
        root.mkdir()
        with (root / ".install.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.install().returncode, 78)
        self.assertFalse((self.root / "bin").exists())
        self.assertEqual(self.install().returncode, 0)

    def test_account_removal_is_rejected_without_changing_manifest(self):
        self.assertEqual(self.install().returncode, 0)
        installed = Path(self.config["install_root"]) / "accounts.json"
        before = installed.read_bytes()
        del self.config["accounts"]["codex-seungpyoson"]
        self.save()
        self.assertEqual(self.install().returncode, 78)
        self.assertEqual(installed.read_bytes(), before)

    def test_api_key_auth_file_is_rejected_without_printing_key(self):
        self.assertEqual(self.install().returncode, 0)
        path = Path(self.config["accounts"]["codex-seungpyoson"]["home"]) / "auth.json"
        path.write_text('{"OPENAI_API_KEY":"synthetic-never-print"}')
        result = self.run_account("codex-seungpyoson", "exec", "hi")
        self.assertEqual(result.returncode, 78)
        self.assertNotIn("synthetic-never-print", result.stdout + result.stderr)

    def test_approved_config_migration_preserves_original_and_auth(self):
        account = self.config["accounts"]["codex-spson.engineering"]
        home = Path(account["home"])
        auth_before = (home / "auth.json").read_bytes()
        old = b"older configuration\n"
        (home / "config.toml").write_bytes(old)
        account["replace_sha256"]["config.toml"] = hashlib.sha256(old).hexdigest()
        self.save()
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue((home / "config.toml").is_symlink())
        self.assertEqual(next((self.root / "installed/preserved").glob("*/codex-spson.engineering/config.toml")).read_bytes(), old)
        self.assertEqual((home / "auth.json").read_bytes(), auth_before)
        self.assertEqual(self.install().returncode, 0)

    def test_install_failure_restores_migrated_file(self):
        account = self.config["accounts"]["codex-seungpyoson"]
        path = Path(account["home"]) / "config.toml"
        old = b"preserve me\n"
        path.write_bytes(old)
        account["replace_sha256"]["config.toml"] = hashlib.sha256(old).hexdigest()
        self.save()
        native_symlink = Path.symlink_to
        def injected(link, target, *args, **kwargs):
            if link == path:
                raise OSError("injected filesystem failure")
            return native_symlink(link, target, *args, **kwargs)
        with patch.object(Path, "symlink_to", injected):
            with self.assertRaisesRegex(OSError, "injected"):
                MODULE.install(self.manifest)
        self.assertEqual(path.read_bytes(), old)
        self.assertFalse((path.parent / "AGENTS.md").exists())

    def test_approved_directory_migration_preserves_contents(self):
        account = self.config["accounts"]["codex-spson.engineering"]
        target = self.root / "shared/skills"
        target.mkdir()
        path = Path(account["home"]) / "skills"
        path.mkdir()
        (path / "keep.txt").write_text("preserved")
        account["shared"]["skills"] = str(target)
        account["replace_directory_identity"]["skills"] = [path.stat().st_dev, path.stat().st_ino]
        self.save()
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(path.resolve(), target.resolve())
        self.assertEqual(next((self.root / "installed/preserved").glob("*/codex-spson.engineering/skills/keep.txt")).read_text(), "preserved")

    def test_unrelated_missing_cli_does_not_block_other_provider(self):
        self.assertEqual(self.install().returncode, 0)
        (self.root / "native-claude").unlink()
        self.assertEqual(self.run_account("codex-seungpyoson", "exec", "hi").returncode, 0)

    def test_named_account_survives_actual_legacy_rsync_projection(self):
        primary = self.root / "legacy-primary"
        primary.mkdir()
        (primary / "AGENTS.md").write_text("canonical policy\n")
        (primary / "config.toml").write_text('model="configured-model"\nmodel_reasoning_effort="max"\n')
        for name in ("skills", "rules", "plugins"):
            (primary / name).mkdir()
            (primary / name / "fixture.txt").write_text("shared content")
        command = "codex-spson.engineering"
        account = self.config["accounts"][command]
        account["shared"] = {n: str(primary / n) for n in ("AGENTS.md", "config.toml", "skills", "rules", "plugins")}
        self.save()
        self.assertEqual(self.install().returncode, 0)
        env = {**self.env, "SECOND_CODEX_SWITCH_ROOT": str(self.root / "legacy-install"),
               "CODEX_A_HOME": str(primary), "SECOND_CODEX_HOME": account["home"],
               "SECOND_CODEX_SHIM_DIR": str(self.root / "legacy-shim"),
               "SECOND_CODEX_PATH_DIR": str(self.root / "legacy-path"),
               "SECOND_CODEX_SWITCH_REAL_CODEX": account["executable"],
               "SECOND_CODEX_MANIFEST": str(SOURCE.parents[1] / "ownership-manifest.txt"),
               "NAMED_AGENT_ACCOUNT": "synthetic-legacy"}
        result = subprocess.run([str(SOURCE.parents[1] / "second-codex"), "exec", "synthetic"],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((Path(account["home"]) / "skills").is_symlink())
        self.assertEqual(self.run_account(command, "exec", "synthetic").returncode, 0)
        self.assertEqual(self.install().returncode, 0)

        skills = primary / "skills"
        moved = self.root / "moved-skills"
        skills.rename(moved)
        # A missing primary target is rejected without deleting the reference.
        result = subprocess.run([str(SOURCE.parents[1] / "second-codex"), "exec", "synthetic"],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 78, result.stderr)
        self.assertTrue((Path(account["home"]) / "skills").is_symlink())
        moved.rename(skills)
        # A different existing target is rejected as well.
        other = self.root / "other-skills"
        other.mkdir()
        linked = Path(account["home"]) / "skills"
        linked.unlink()
        linked.symlink_to(other)
        result = subprocess.run([str(SOURCE.parents[1] / "second-codex"), "exec", "synthetic"],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 78, result.stderr)
        self.assertEqual(linked.resolve(), other.resolve())

    def test_claude_empty_and_wrong_login_are_rejected(self):
        self.assertEqual(self.install().returncode, 0)
        exe = self.root / "native-claude"
        for status, expected in [({"loggedIn": False}, "Not signed in"),
                                 ({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "another@example.invalid"}, "does not match")]:
            exe.write_text("#!/usr/bin/env python3\nprint(" + repr(json.dumps(status)) + ")\n")
            result = self.run_account("claude-sp.openclaw", "-p", "hi")
            self.assertEqual(result.returncode, 78)
            self.assertIn(expected, result.stderr)

    def test_native_settings_replacement_keeps_model_defaults_and_can_reinstall(self):
        self.assertEqual(self.install().returncode, 0)
        home = Path(self.config["accounts"]["codex-spson.engineering"]["home"])
        path = home / "config.toml"
        path.unlink()
        path.write_text('model="local-choice"\nmodel_reasoning_effort="low"\n[projects."example"]\ntrust_level="trusted"\n')
        result = self.run_account("codex-spson.engineering", "exec", "hi")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('model="configured-model"', json.loads(result.stdout)["args"])
        self.assertIn('model_reasoning_effort="max"', json.loads(result.stdout)["args"])
        # Old installations and new manifests may spell the same home differently.
        installed = self.root / "installed/accounts.json"
        prior = json.loads(installed.read_text())
        prior["accounts"]["codex-spson.engineering"]["home"] += "/./"
        installed.write_text(json.dumps(prior))
        self.config["accounts"]["codex-spson.engineering"]["home"] += "//"
        self.save()
        self.assertEqual(self.install().returncode, 0)
        self.assertIn("trust_level", path.read_text())

    def test_changed_install_manifest_can_move_command_directory(self):
        self.assertEqual(self.install().returncode, 0)
        self.config["bin_dir"] = str(self.root / "new-bin")
        self.save()
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue((self.root / "new-bin/codex-seungpyoson").is_symlink())

    def test_moved_shared_source_retargets_only_owned_links(self):
        for account in self.config["accounts"].values():
            account["shared"] = {name: str(self.root / "shared") + "//" + name + "/"
                                 for name in account["shared"]}
        self.save()
        self.assertEqual(self.install().returncode, 0)
        source = self.root / "shared"
        moved = self.root / "shared-moved"
        source.rename(moved)
        for account in self.config["accounts"].values():
            account["shared"] = {name: str(moved / name) for name in account["shared"]}
        self.save()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_account("codex-seungpyoson", "exec", "hi").returncode, 0)
        path = Path(self.config["accounts"]["codex-seungpyoson"]["home"]) / "AGENTS.md"
        path.unlink()
        path.symlink_to(self.root / "unowned-target")
        self.assertEqual(self.install().returncode, 78)

    def test_model_defaults_do_not_duplicate_native_model_option(self):
        self.assertEqual(self.install().returncode, 0)
        result = self.run_account("codex-seungpyoson", "--model", "explicit-model", "exec", "hi")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)["args"]
        self.assertEqual(args.count("--model"), 1)
        self.assertIn('model="configured-model"', args)

    def test_option_values_cannot_bypass_identity_check(self):
        self.assertEqual(self.install().returncode, 0)
        exe = self.root / "native-claude"
        exe.write_text("#!/usr/bin/env python3\nprint('{\"loggedIn\":false}')\n")
        for args in (["--append-system-prompt", "auth", "task"],
                     ["--unknown-future-option", "auth", "task"],
                     ["--add-dir", "some-directory", "auth", "-p", "task"]):
            result = self.run_account("claude-sp.openclaw", *args)
            self.assertEqual(result.returncode, 78, result.stderr)
            self.assertIn("Not signed in", result.stderr)

    def test_claude_model_effort_defaults_and_case_normalized_identity(self):
        (self.root / "shared/settings.json").write_text('{"model":"opus","effortLevel":"max"}')
        self.assertEqual(self.install().returncode, 0)
        exe = self.root / "native-claude"
        exe.write_text(exe.read_text().replace("home.name+'@example.invalid'", "home.name.upper()+'@example.invalid'"))
        result = self.run_account("claude-sp.openclaw", "--model", "explicit", "--effort", "high", "-p", "hi")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)["args"]
        self.assertEqual(args[:4], ["--model", "opus", "--effort", "max"])
        self.assertEqual(args[4:8], ["--model", "explicit", "--effort", "high"])
        self.assertNotIn("--settings", args)

    def test_claude_effort_cannot_silently_fall_back_or_be_overridden_by_environment(self):
        self.assertEqual(self.install().returncode, 0)
        settings = self.root / "shared/settings.json"
        for effort in (None, True, 42, [], "not-a-native-effort"):
            settings.write_text(json.dumps({"model": "opus", "effortLevel": effort}))
            result = self.run_account("claude-sp.openclaw", "-p", "hi")
            self.assertEqual(result.returncode, 78)
            self.assertIn("Invalid Claude effortLevel", result.stderr)
            self.assertEqual(result.stdout, "")
        settings.write_text('{"model":"opus","effortLevel":"max"}')
        result = self.run_account("claude-sp.openclaw", "--effort", "high", "-p", "hi",
                                  env={**self.env, "CLAUDE_CODE_EFFORT_LEVEL": "low"})
        self.assertEqual(result.returncode, 78)
        self.assertIn("CLAUDE_CODE_EFFORT_LEVEL", result.stderr)

    def test_canonical_provider_overrides_and_claude_api_helpers_are_rejected(self):
        self.assertEqual(self.install().returncode, 0)
        cfg = self.root / "shared/config.toml"
        cfg.write_text(cfg.read_text() + '\nprofile="alternate"\n')
        self.assertEqual(self.run_account("codex-seungpyoson", "exec", "hi").returncode, 78)
        (self.root / "shared/settings.json").write_text('{"model":"opus","apiKeyHelper":"a-helper"}')
        self.assertEqual(self.run_account("claude-sp.openclaw", "-p", "hi").returncode, 78)

    def test_metadata_write_failure_rolls_back_and_retry_succeeds(self):
        original = MODULE.atomic_write
        def injected(path, content, mode):
            if path.name == "accounts.json":
                raise OSError("injected metadata failure")
            return original(path, content, mode)
        with patch.object(MODULE, "atomic_write", injected):
            with self.assertRaisesRegex(OSError, "metadata"):
                MODULE.install(self.manifest)
        self.assertFalse((self.root / "installed/named_accounts.py").exists())
        self.assertFalse((self.root / "bin/codex-seungpyoson").exists())
        self.assertEqual(self.install().returncode, 0)

    def test_one_cleanup_error_does_not_skip_other_restorations(self):
        account = self.config["accounts"]["codex-seungpyoson"]
        home = Path(account["home"])
        originals = {"AGENTS.md": b"old rules", "config.toml": b"old config"}
        for name, content in originals.items():
            (home / name).write_bytes(content)
            account["replace_sha256"][name] = hashlib.sha256(content).hexdigest()
        self.save()
        unlink = Path.unlink
        def cannot_remove_one_link(path, *args, **kwargs):
            if path == home / "AGENTS.md":
                raise OSError("injected unlink error")
            return unlink(path, *args, **kwargs)
        with patch.object(MODULE, "atomic_write", side_effect=OSError("injected install error")), patch.object(Path, "unlink", cannot_remove_one_link):
            with self.assertRaises(BaseExceptionGroup):
                MODULE.install(self.manifest)
        for name, content in originals.items():
            self.assertEqual((home / name).read_bytes(), content)

    def test_stale_policy_and_unknown_command_fail_closed(self):
        self.assertEqual(self.install().returncode, 0)
        account = self.config["accounts"]["codex-seungpyoson"]
        policy = Path(account["home"]) / "AGENTS.md"
        policy.unlink()
        policy.write_text("stale policy")
        self.assertEqual(self.run_account("codex-seungpyoson", "exec", "hi").returncode, 78)
        unknown = self.root / "bin/codex-unknown"
        unknown.symlink_to(self.root / "installed/named_accounts.py")
        self.assertEqual(self.run_account("codex-unknown", "exec", "hi").returncode, 78)

    def test_runtime_paths_cannot_be_shared_and_native_exit_is_preserved(self):
        account = self.config["accounts"]["codex-seungpyoson"]
        account["shared"]["auth.json"] = str(Path(account["home"]) / "auth.json")
        self.save()
        self.assertEqual(self.install().returncode, 78)
        del account["shared"]["auth.json"]
        self.save()
        self.assertEqual(self.install().returncode, 0)
        (Path(account["home"]) / "native-exit").write_text("42")
        self.assertEqual(self.run_account("codex-seungpyoson", "exec", "hi").returncode, 42)


if __name__ == "__main__":
    unittest.main()
