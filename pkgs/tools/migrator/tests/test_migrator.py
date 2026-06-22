import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class MigratorScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.helper = cls.repo_root / "pkgs/tools/migrator/migrator-helper.sh"
        cls.control = cls.repo_root / "pkgs/tools/migrator/migratorctl.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="migrator-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.fake_bin.mkdir()
        self.systemctl_log = self.work_dir / "systemctl.log"
        self.manifest = self.work_dir / "manifest.json"
        self.gate = self.work_dir / "gate"
        self.helper_source = self.strip_main(self.helper, "migrator-helper-test-source.sh")
        self.control_source = self.strip_main(self.control, "migratorctl-test-source.sh")
        self.write_executable(
            self.fake_bin / "systemctl",
            "#!/bin/sh\nif [ \"$1\" = show ]; then printf 'loaded\\n'; else printf '%s\\n' \"$*\" >>\"$SYSTEMCTL_LOG\"; fi\n",
        )
        self.write_executable(
            self.fake_bin / "ssh",
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$SSH_LOG\"\n",
        )
        self.manifest.write_text(
            json.dumps(
                {
                    "systemUnits": [
                        {
                            "unit": "stop-only.service",
                            "stopOnDrain": True,
                            "startOnResume": False,
                        },
                        {
                            "unit": "start-only.service",
                            "stopOnDrain": False,
                            "startOnResume": True,
                        },
                        {"unit": "defaulted.service"},
                    ],
                    "dispatcherUnits": ["dispatcher.service"],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def strip_main(self, script, name):
        output = self.work_dir / name
        output.write_text(
            script.read_text(encoding="utf-8").replace('\nmain "$@"\n', "\n"),
            encoding="utf-8",
        )
        return output

    def write_executable(self, path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def run_bash(self, script, body, *, check=True, env=None):
        full_env = os.environ.copy()
        full_env.update(
            {
                "PATH": f"{self.fake_bin}:{full_env['PATH']}",
                "MIGRATOR_GATE_PATH": str(self.gate),
                "MIGRATOR_MANIFEST": str(self.manifest),
                "SYSTEMCTL_LOG": str(self.systemctl_log),
                "SSH_LOG": str(self.work_dir / "ssh.log"),
            }
        )
        full_env.update(env or {})
        return subprocess.run(
            [
                "bash",
                "-c",
                textwrap.dedent(
                    f"""
                    set -Eeuo pipefail
                    source {script}
                    {body}
                    """
                ),
            ],
            cwd=self.repo_root,
            env=full_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_helper_apply_respects_gate_manifest_and_dispatchers(self):
        self.run_bash(
            self.helper_source,
            """
            init_vars
            apply_current_gate
            """,
        )
        self.assertEqual(
            ["start start-only.service", "start defaulted.service", "restart dispatcher.service"],
            self.systemctl_log.read_text(encoding="utf-8").splitlines(),
        )

        self.gate.touch()
        self.systemctl_log.write_text("", encoding="utf-8")
        self.run_bash(
            self.helper_source,
            """
            init_vars
            apply_current_gate
            """,
        )
        self.assertEqual(
            ["stop --wait stop-only.service", "stop --wait defaulted.service", "restart dispatcher.service"],
            self.systemctl_log.read_text(encoding="utf-8").splitlines(),
        )

    def test_helper_sync_accepts_declared_states_and_rejects_unknown_state(self):
        self.run_bash(self.helper_source, "init_vars; set_declared_gate_state", env={"MIGRATOR_DECLARED_STATE": "on"})
        self.assertTrue(self.gate.exists())

        self.run_bash(self.helper_source, "init_vars; set_declared_gate_state", env={"MIGRATOR_DECLARED_STATE": "off"})
        self.assertFalse(self.gate.exists())

        invalid = self.run_bash(
            self.helper_source,
            "init_vars; set_declared_gate_state",
            check=False,
            env={"MIGRATOR_DECLARED_STATE": "broken"},
        )
        self.assertNotEqual(0, invalid.returncode)
        self.assertIn("unsupported MIGRATOR_DECLARED_STATE", invalid.stderr)

    def test_control_local_gate_status_and_apply(self):
        result = self.run_bash(
            self.control_source,
            """
            init_vars
            set_local_gate on
            local_status
            set_local_gate off
            local_status
            local_apply
            """,
        )

        self.assertEqual(["on", "off"], result.stdout.splitlines())
        self.assertEqual(["restart --wait migrator-apply.service"], self.systemctl_log.read_text(encoding="utf-8").splitlines())

    def test_control_remote_main_delegates_supported_actions(self):
        result = self.run_bash(
            self.control_source,
            """
            init_vars
            remote_exec() { printf '%s\n' "$*"; }
            remote_main on --host abird-corp
            remote_main apply --host abird-data
            """,
        )

        self.assertEqual(
            [
                "abird-corp sudo /run/current-system/sw/bin/migratorctl on",
                "abird-data sudo /run/current-system/sw/bin/migratorctl apply",
            ],
            result.stdout.splitlines(),
        )

    def test_control_ssh_options_include_known_hosts_identity_and_proxy_jump(self):
        key = self.work_dir / "id_ed25519"
        key.write_text("key\n", encoding="utf-8")
        result = self.run_bash(
            self.control_source,
            f"""
            init_vars
            repo_root={self.work_dir}
            load_nixbot_host_json() {{
              case "$1" in
                jump) jq -cn '{{user:"jumpuser",target:"jump.example",port:2200,key:"",knownHosts:"",proxyJump:"",proxyCommand:""}}' ;;
                *) jq -cn --arg key {key} '{{user:"deploy",target:"target.example",port:2222,key:$key,knownHosts:"target ssh-ed25519 AAAA",proxyJump:"jump",proxyCommand:""}}' ;;
              esac
            }}
            ssh_opts_from_host_json "$(load_nixbot_host_json target)" | tr '\\0' '\\n'
            """,
        )

        lines = result.stdout.splitlines()
        self.assertIn("-p", lines)
        self.assertIn("2222", lines)
        self.assertIn("-i", lines)
        self.assertIn(str(key), lines)
        proxy = next(line for line in lines if line.startswith("ProxyCommand="))
        self.assertIn("%h %p", proxy)
        self.assertTrue(Path(proxy.split("=", 1)[1].split()[0]).is_file())


if __name__ == "__main__":
    unittest.main()
