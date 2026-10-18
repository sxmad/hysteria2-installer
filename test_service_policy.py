#!/usr/bin/env python3
"""Recovery policy regressions; all writes and service actions are isolated."""

import configparser
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).with_name("install.sh")


class RecoveryPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hy2-recovery-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.dropins = self.root / "hysteria-server.service.d"
        self.policy = self.dropins / "20-hysteria2-installer.conf"
        self.events = self.root / "events"
        self.binary = self.root / "hysteria"
        self.binary.write_text("#!/bin/sh\nexit 0\n")
        self.binary.chmod(0o755)
        self.config = self.root / "config"
        self.config.mkdir()
        (self.config / "config.yaml").write_text("auth: existing-password\n")
        source = INSTALLER.read_text().replace('\nmain "$@"\n', '\n')
        for name, path in {
            "SERVICE_DROPIN_DIR": self.dropins,
            "CONFIG_DIR": self.config,
            "HYSTERIA_HOME_DIR": self.root / "home",
            "STATE_DIR": self.root / "state",
            "BACKUP_DIR": self.root / "backups",
        }.items():
            lines = source.splitlines()
            source = "\n".join(
                f"readonly {name}={shlex.quote(str(path))}"
                if line.startswith(f"readonly {name}=") else line
                for line in lines
            ) + "\n"
        source = source.replace("/usr/local/bin/hysteria", str(self.binary))
        source = source.replace("[[ -d /run/systemd/system ]]", "true")
        self.functions = self.root / "functions.sh"
        self.functions.write_text(source)

    def run_bash(self, script, success=True):
        result = subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(self.functions))}\n" + script],
            env={**os.environ, "EVENTS": str(self.events)},
            text=True, capture_output=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_bounded_recovery_and_accounting_without_scheduled_restart(self):
        self.run_bash("write_service_policy\nwrite_service_policy")
        config = configparser.ConfigParser()
        config.read(self.policy)
        self.assertEqual(config["Service"]["Restart"], "on-failure")
        self.assertEqual(config["Service"]["RestartSec"], "5s")
        self.assertEqual(config["Unit"]["StartLimitIntervalSec"], "300")
        self.assertEqual(config["Unit"]["StartLimitBurst"], "5")
        self.assertEqual(config["Service"]["MemoryAccounting"], "true")
        for disruptive_setting in ("RuntimeMaxSec", "MemoryMax", "WatchdogSec"):
            self.assertNotIn(disruptive_setting, config["Service"])
        self.assertEqual(self.policy.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.dropins.stat().st_mode & 0o777, 0o755)

    def test_unknown_file_is_preserved_on_write_and_remove(self):
        self.dropins.mkdir()
        self.policy.write_text("# Administrator settings\n[Service]\nRestart=no\n")
        original = self.policy.read_bytes()
        self.run_bash("write_service_policy", success=False)
        self.run_bash("remove_service_policy")
        self.assertEqual(self.policy.read_bytes(), original)

    def test_symlink_file_and_directory_are_preserved(self):
        target = self.root / "administrator.conf"
        target.write_text("keep me\n")
        self.dropins.mkdir()
        self.policy.symlink_to(target)
        self.run_bash("write_service_policy", success=False)
        self.run_bash("remove_service_policy")
        self.assertTrue(self.policy.is_symlink())
        self.assertEqual(target.read_text(), "keep me\n")
        self.policy.unlink()
        self.dropins.rmdir()
        target_dir = self.root / "administrator-directory"
        target_dir.mkdir()
        self.dropins.symlink_to(target_dir, target_is_directory=True)
        self.run_bash("write_service_policy", success=False)
        self.run_bash("remove_service_policy")
        self.assertTrue(self.dropins.is_symlink())
        self.assertEqual(list(target_dir.iterdir()), [])

    def test_failed_atomic_replace_keeps_previous_policy(self):
        self.run_bash("write_service_policy")
        original = self.policy.read_bytes()
        self.run_bash("mv() { return 1; }; write_service_policy", success=False)
        self.assertEqual(self.policy.read_bytes(), original)
        self.assertEqual(list(self.dropins.iterdir()), [self.policy])

    def test_cleanup_keeps_other_dropins_and_removes_empty_owned_directory(self):
        self.run_bash("write_service_policy")
        custom = self.dropins / "90-custom.conf"
        custom.write_text("[Service]\nEnvironment=EXAMPLE=1\n")
        self.run_bash("remove_service_policy")
        self.assertFalse(self.policy.exists())
        self.assertTrue(custom.exists())
        custom.unlink()
        self.run_bash("write_service_policy\nremove_service_policy")
        self.assertFalse(self.dropins.exists())

    def workflow_mocks(self, active):
        return f"""
require_root() {{ :; }}
require_command() {{ :; }}
backup_config() {{ :; }}
run_official_installer() {{ printf 'installer\\n' >>"$EVENTS"; }}
systemctl() {{
  local IFS=' '
  printf '%s\\n' "$*" >>"$EVENTS"
  if [[ "$1" == is-active ]]; then return {0 if active else 1}; fi
}}
wait_for_service_with_recovery() {{ printf 'startup\\n' >>"$EVENTS"; }}
"""

    def test_update_installs_policy_and_preserves_stopped_or_running_state(self):
        for active in (False, True):
            with self.subTest(active=active):
                self.events.unlink(missing_ok=True)
                self.run_bash(self.workflow_mocks(active) + "update_hysteria")
                events = self.events.read_text().splitlines()
                self.assertTrue(self.policy.exists())
                self.assertIn("daemon-reload", events)
                self.assertEqual("restart hysteria-server.service" in events, active)
                self.assertEqual("startup" in events, active)
                self.assertNotIn("start hysteria-server.service", events)
                self.assertEqual((self.config / "config.yaml").read_text(), "auth: existing-password\n")

    def test_update_rejects_unmanaged_collision_before_downloading(self):
        self.dropins.mkdir()
        self.policy.write_text("# custom\n")
        self.run_bash(self.workflow_mocks(True) + "update_hysteria", success=False)
        self.assertFalse(self.events.exists())
        self.assertEqual(self.policy.read_text(), "# custom\n")

    def test_uninstall_removes_only_owned_policy(self):
        self.run_bash("write_service_policy")
        custom = self.dropins / "90-custom.conf"
        custom.write_text("[Service]\nEnvironment=EXAMPLE=1\n")
        self.run_bash(self.workflow_mocks(False) + """
download_official_installer() { printf '#!/bin/bash\\nexit 0\\n' >"$1"; }
YES=1
uninstall_hysteria
""")
        self.assertFalse(self.policy.exists())
        self.assertTrue(custom.exists())
        self.assertFalse((self.config / "config.yaml").exists())
        self.assertIn("daemon-reload", self.events.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
