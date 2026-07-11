import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


class StalwartHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.helper = cls.repo_root / "lib/services/stalwart/helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="stalwart-helper-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.state_dir = self.work_dir / "state"
        self.secret_dir = self.work_dir / "secret"
        self.fake_bin.mkdir()
        self.state_dir.mkdir()
        self.secret_dir.mkdir()
        self.log_file = self.state_dir / "stalwart.log"
        self.log_file.touch()
        self._write_fake_podman()
        self._write_fake_stalwart_cli()

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def _write_executable(self, path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_stalwart_cli(self):
        self._write_executable(
            self.fake_bin / "stalwart-cli",
            f"#!{shutil.which('bash')}\nexit 0\n",
        )

    def _write_fake_podman(self):
        self._write_executable(
            self.fake_bin / "podman",
            f"#!{shutil.which('bash')}\nexec {sys.executable} {Path(__file__).with_name('fake_podman.py')} \"$@\"\n",
        )

    def helper_env(self, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "TEST_STALWART_LOG": str(self.log_file),
                "TEST_STALWART_STATE_DIR": str(self.state_dir),
                "STALWART_CLI_BIN": str(self.fake_bin / "stalwart-cli"),
                "STALWART_IMAGE": "mock-image",
                "STALWART_RECOVERY_CONTAINER": "mock-recovery",
                "STALWART_RECOVERY_URL": "http://127.0.0.1:18081",
                "STALWART_DOMAIN_ID": "__domain__",
                "STALWART_DOMAIN_NAME": "abird.ai",
            }
        )
        env.update(overrides)
        return env

    def run_helper(self, script: str, *, check=True, **env_overrides):
        prelude = f"""
            set -Eeuo pipefail
            source {self.helper}
            init_vars
            stalwart_recovery_secret_dir={self.secret_dir}
        """
        return subprocess.run(
            ["bash", "-c", textwrap.dedent(prelude + script)],
            cwd=self.repo_root,
            env=self.helper_env(**env_overrides),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def write_plan(self, name: str, *lines: str) -> Path:
        path = self.work_dir / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def test_recovery_api_probe_uses_list_object(self):
        self.run_helper(
            "wait_for_recovery_api",
            NOTIFY_SOCKET="/run/systemd/notify",
            WATCHDOG_PID="123",
            WATCHDOG_USEC="1000000",
        )
        log = self.log_file.read_text(encoding="utf-8")
        self.assertIn("query Domain --fields id --json", log)
        self.assertNotIn("query SystemSettings", log)

    def test_successful_recovery_cleans_up_before_function_scope_ends(self):
        config = self.work_dir / "config.json"
        plan = self.work_dir / "plan.json"
        token = self.work_dir / "ldap-token"
        data_dir = self.work_dir / "data"
        config.write_text("{}\n", encoding="utf-8")
        plan.write_text("{}\n", encoding="utf-8")
        token.write_text("token\n", encoding="utf-8")
        data_dir.mkdir()

        result = self.run_helper(
            f"""
            stalwart_config_host_path={config}
            stalwart_container=mock-stalwart
            stalwart_data_dir={data_dir}
            stalwart_kanidm_ldap_token_host_path={token}
            stalwart_plan_container_path=/etc/stalwart/plan.json
            stalwart_plan_host_path={plan}
            stalwart_service_name=mock-stalwart
            with_recovery true
            printf 'recovery-complete\\n'
            """
        )

        self.assertEqual("recovery-complete", result.stdout.strip())

    def test_recovery_retries_transient_podman_engine_failures(self):
        config = self.work_dir / "retry-config.json"
        plan = self.work_dir / "retry-plan.json"
        token = self.work_dir / "retry-ldap-token"
        data_dir = self.work_dir / "retry-data"
        config.write_text("{}\n", encoding="utf-8")
        plan.write_text("{}\n", encoding="utf-8")
        token.write_text("token\n", encoding="utf-8")
        data_dir.mkdir()

        result = self.run_helper(
            f"""
            stalwart_config_host_path={config}
            stalwart_container=mock-stalwart
            stalwart_data_dir={data_dir}
            stalwart_kanidm_ldap_token_host_path={token}
            stalwart_plan_container_path=/etc/stalwart/plan.json
            stalwart_plan_host_path={plan}
            stalwart_runtime_retry_delay_seconds=0
            stalwart_service_name=mock-stalwart
            with_recovery true
            """,
            TEST_STALWART_RECOVERY_FAILURES="2",
            NOTIFY_SOCKET="/run/systemd/notify",
            WATCHDOG_PID="123",
            WATCHDOG_USEC="1000000",
        )

        self.assertEqual(0, result.returncode)
        self.assertEqual(
            "3",
            (self.state_dir / "recovery-run-attempts").read_text(encoding="utf-8"),
        )

    def test_recovery_reports_final_podman_engine_error(self):
        result = self.run_helper(
            """
            stalwart_runtime_retry_attempts=2
            stalwart_runtime_retry_delay_seconds=0
            runtime_run_recovery mock-image mock-recovery
            """,
            check=False,
            TEST_STALWART_RECOVERY_FAILURES="2",
        )

        self.assertEqual(125, result.returncode)
        self.assertIn("transient podman engine failure", result.stderr)
        self.assertIn(
            "failed to create Stalwart recovery container after 2 attempt(s): "
            "mock-recovery (status 125)",
            result.stderr,
        )

    def test_plan_string_file_substitution(self):
        value_file = self.work_dir / "ldap-token"
        value_file.write_text("secret-token\n", encoding="utf-8")
        plan = self.write_plan(
            "plan-substitution.ndjson",
            '{"@type":"update","object":"Directory","value":{"bindSecret":"__ldap_token__"}}',
        )

        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            stalwart_plan_string_file_substitutions=$'__ldap_token__\\t'{value_file}
            prepare_plan_host_path
            """
        )
        rendered = Path(result.stdout.strip())
        self.assertNotEqual(plan, rendered)
        self.assertIn("secret-token", rendered.read_text(encoding="utf-8"))
        self.assertNotIn("__ldap_token__", rendered.read_text(encoding="utf-8"))

    def test_json_token_rewrite_uses_unique_paths(self):
        plan = self.write_plan("rewrite.json", '{"first":"old-a","second":"old-b"}')
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            rewrite_json_file_token_var stalwart_plan_host_path plan-rewrite old-a live-a
            printf '%s\\n' "$stalwart_plan_host_path"
            rewrite_json_file_token_var stalwart_plan_host_path plan-rewrite old-b live-b
            printf '%s\\n' "$stalwart_plan_host_path"
            """
        )
        first, second = [Path(line) for line in result.stdout.splitlines()]
        self.assertNotEqual(first, second)
        rendered = second.read_text(encoding="utf-8")
        self.assertIn("live-a", rendered)
        self.assertIn("live-b", rendered)
        self.assertNotIn("old-a", rendered)
        self.assertNotIn("old-b", rendered)

    def test_json_token_rewrite_failure_is_fatal(self):
        plan = self.write_plan("rewrite-failure.json", '{"id":"old"}')
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            stalwart_recovery_secret_dir={self.work_dir / "missing-secret-dir"}
            rewrite_json_file_token_var stalwart_plan_host_path blocked old new
            """,
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("No such file or directory", result.stderr)

    def test_directory_resolution_rewrites_multiple_ids(self):
        plan = self.write_plan(
            "directories.ndjson",
            '{"@type":"update","object":"Directory","id":"old-a","value":{"description":"A","url":"ldap://a"}}',
            '{"@type":"update","object":"Authentication","value":{"directoryId":"old-a"}}',
            '{"@type":"update","object":"Directory","id":"old-b","value":{"description":"B","url":"ldap://b"}}',
            '{"@type":"update","object":"Domain","id":"domain","value":{"directoryId":"old-b"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_directory_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """,
            TEST_STALWART_DIRECTORY_MODE="two",
        )
        rendered = Path(result.stdout.strip()).read_text(encoding="utf-8")
        self.assertIn("live-a", rendered)
        self.assertIn("live-b", rendered)
        self.assertNotIn("old-a", rendered)
        self.assertNotIn("old-b", rendered)

    def test_directory_duplicate_match_resolves_deterministically(self):
        plan = self.write_plan(
            "directory-duplicate.ndjson",
            '{"@type":"update","object":"Directory","id":"old-a","value":{"description":"A","url":"ldap://a"}}',
            '{"@type":"update","object":"Authentication","value":{"directoryId":"old-a"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_directory_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """,
            TEST_STALWART_DIRECTORY_MODE="duplicate",
        )
        rendered = Path(result.stdout.strip()).read_text(encoding="utf-8")
        self.assertIn("live-a", rendered)
        self.assertNotIn("old-a", rendered)
        self.assertNotIn("live-a2", rendered)

    def test_directory_resolution_prefers_existing_id_over_duplicate_description(self):
        plan = self.write_plan(
            "directory-duplicate-existing-id.ndjson",
            '{"@type":"update","object":"Directory","id":"live-a","value":{"description":"A","url":"ldap://a"}}',
            '{"@type":"update","object":"Authentication","value":{"directoryId":"live-a"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_directory_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """,
            TEST_STALWART_DIRECTORY_MODE="duplicate",
        )
        rendered = Path(result.stdout.strip()).read_text(encoding="utf-8")
        self.assertIn("live-a", rendered)
        self.assertNotIn("multiple Stalwart directories match description", result.stderr)

    def test_directory_missing_dry_run_fails_before_create(self):
        plan = self.write_plan(
            "directory-missing.ndjson",
            '{"@type":"update","object":"Directory","id":"old-missing","value":{"description":"Missing Directory","url":"ldap://missing"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_directory_apply_inputs --dry-run
            """,
            check=False,
            TEST_STALWART_DIRECTORY_MODE="missing",
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("non-dry apply would create it", result.stderr)
        self.assertNotIn("create Directory", self.log_file.read_text(encoding="utf-8"))

    def test_directory_missing_apply_creates_and_rewrites(self):
        plan = self.write_plan(
            "directory-create.ndjson",
            '{"@type":"update","object":"Directory","id":"old-missing","value":{"description":"Missing Directory","url":"ldap://missing"}}',
            '{"@type":"update","object":"Authentication","value":{"directoryId":"old-missing"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_directory_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """,
            TEST_STALWART_DIRECTORY_MODE="create",
        )
        self.assertTrue((self.state_dir / "directory-created").exists())
        self.assertIn("Missing Directory", (self.state_dir / "directory-create.json").read_text())
        rendered = Path(result.stdout.splitlines()[-1]).read_text(encoding="utf-8")
        self.assertIn("created-directory", rendered)
        self.assertNotIn("old-missing", rendered)

    def test_network_listener_resolution_rewrites_multiple_ids(self):
        plan = self.write_plan(
            "listeners.ndjson",
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_http__","value":{"name":"http","bind":{"0.0.0.0:8080":true}}}',
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_smtp__","value":{"name":"smtp","bind":{"0.0.0.0:25":true}}}',
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_submissions__","value":{"name":"submissions","bind":{"0.0.0.0:465":true}}}',
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_imaps__","value":{"name":"imaps","bind":{"0.0.0.0:993":true}}}',
            '{"@type":"update","object":"SystemSettings","value":{"httpListenerId":"__network_listener_http__","imapsListenerId":"__network_listener_imaps__"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_network_listener_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """
        )
        rendered = Path(result.stdout.strip()).read_text(encoding="utf-8")
        self.assertIn("live-http", rendered)
        self.assertIn("live-smtp", rendered)
        self.assertIn("live-submissions", rendered)
        self.assertIn("live-imaps", rendered)
        self.assertNotIn("__network_listener_http__", rendered)
        self.assertNotIn("__network_listener_smtp__", rendered)
        self.assertNotIn("__network_listener_submissions__", rendered)
        self.assertNotIn("__network_listener_imaps__", rendered)
        self.assertNotIn('"name":"http"', rendered)
        self.assertNotIn('"name":"smtp"', rendered)
        self.assertNotIn('"name":"submissions"', rendered)
        self.assertNotIn('"name":"imaps"', rendered)

    def test_network_listener_updates_without_name_are_not_rewritten(self):
        plan = self.write_plan(
            "listener-no-name.ndjson",
            '{"@type":"update","object":"NetworkListener","id":"literal-id","value":{"bind":{"0.0.0.0:8080":true}}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_network_listener_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """
        )
        rendered = Path(result.stdout.strip()).read_text(encoding="utf-8")
        self.assertIn("literal-id", rendered)

    def test_network_listener_create_names_are_kept(self):
        plan = self.write_plan(
            "listener-create-name.ndjson",
            '{"@type":"create","object":"NetworkListener","value":{"custom":{"name":"custom","protocol":"smtp"}}}',
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_http__","value":{"name":"http","bind":{"0.0.0.0:8080":true}}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_network_listener_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """
        )
        rendered = Path(result.stdout.strip()).read_text(encoding="utf-8")
        self.assertIn('"name":"custom"', rendered)
        self.assertNotIn('"name":"http"', rendered)

    def test_network_listener_duplicate_match_fails(self):
        plan = self.write_plan(
            "listener-duplicate.ndjson",
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_http__","value":{"name":"http"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_network_listener_apply_inputs
            """,
            check=False,
            TEST_STALWART_NETWORK_LISTENER_MODE="duplicate",
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("multiple Stalwart network listeners match name: http", result.stderr)

    def test_network_listener_missing_match_fails(self):
        plan = self.write_plan(
            "listener-missing.ndjson",
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_http__","value":{"name":"http"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_network_listener_apply_inputs
            """,
            check=False,
            TEST_STALWART_NETWORK_LISTENER_MODE="missing",
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("declare it as a create operation before updating it", result.stderr)

    def test_domain_resolution_rewrites_plan_and_side_files(self):
        plan = self.write_plan(
            "domain-plan.ndjson",
            '{"@type":"update","object":"Domain","id":"__domain__","value":{"name":"abird.ai"}}',
        )
        roles = self.write_plan("roles.json", '{"domainId":"__domain__"}')
        lists = self.write_plan("mailing-lists.json", '{"domainId":"__domain__"}')
        groups = self.write_plan("groups.json", '{"domainId":"__domain__"}')
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            stalwart_user_roles_host_path={roles}
            stalwart_mailing_lists_host_path={lists}
            stalwart_shared_mailboxes_host_path={groups}
            prepare_primary_domain_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            printf '%s\\n' "$stalwart_user_roles_host_path"
            printf '%s\\n' "$stalwart_mailing_lists_host_path"
            printf '%s\\n' "$stalwart_shared_mailboxes_host_path"
            """,
            TEST_STALWART_DOMAIN_MODE="present",
        )
        for line in result.stdout.splitlines():
            rendered = Path(line).read_text(encoding="utf-8")
            self.assertIn("live-domain", rendered)
            self.assertNotIn("__domain__", rendered)

    def test_domain_duplicate_match_fails(self):
        plan = self.write_plan(
            "domain-duplicate.ndjson",
            '{"@type":"update","object":"Domain","id":"__domain__","value":{"name":"abird.ai"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_primary_domain_apply_inputs
            """,
            check=False,
            TEST_STALWART_DOMAIN_MODE="duplicate",
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("multiple Stalwart domains match name: abird.ai", result.stderr)

    def test_domain_missing_apply_creates_and_rewrites(self):
        plan = self.write_plan(
            "domain-create.ndjson",
            '{"@type":"update","object":"Domain","id":"__domain__","value":{"name":"abird.ai","description":"Primary domain"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_primary_domain_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """,
            TEST_STALWART_DOMAIN_MODE="create",
        )
        self.assertTrue((self.state_dir / "domain-created").exists())
        self.assertIn("Primary domain", (self.state_dir / "domain-create.json").read_text())
        rendered = Path(result.stdout.splitlines()[-1]).read_text(encoding="utf-8")
        self.assertIn("created-domain", rendered)
        self.assertNotIn("__domain__", rendered)

    def test_apply_input_preparation_resolves_directory_before_domain(self):
        plan = self.write_plan(
            "apply-order.ndjson",
            '{"@type":"update","object":"Directory","id":"old-directory","value":{"description":"Kanidm LDAP","url":"ldap://kanidm"}}',
            '{"@type":"update","object":"NetworkListener","id":"__network_listener_http__","value":{"name":"http","bind":{"0.0.0.0:8080":true}}}',
            '{"@type":"update","object":"Domain","id":"__domain__","value":{"name":"abird.ai","directoryId":"old-directory"}}',
        )
        result = self.run_helper(
            f"""
            stalwart_plan_host_path={plan}
            prepare_apply_inputs
            printf '%s\\n' "$stalwart_plan_host_path"
            """,
            TEST_STALWART_DIRECTORY_MODE="present",
            TEST_STALWART_DOMAIN_MODE="present",
        )
        rendered = Path(result.stdout.strip()).read_text(encoding="utf-8")
        self.assertIn("live-directory", rendered)
        self.assertIn("live-http", rendered)
        self.assertIn("live-domain", rendered)
        self.assertNotIn("old-directory", rendered)
        self.assertNotIn("__network_listener_http__", rendered)
        self.assertNotIn('"name":"http"', rendered)
        self.assertNotIn("__domain__", rendered)


if __name__ == "__main__":
    unittest.main()
