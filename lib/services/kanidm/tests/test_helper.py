"""Exercise OAuth redirect policy and verified declarative auto-apply stamps."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class OAuthRedirectPolicyTest(unittest.TestCase):
    def run_helper(self, client, live=None):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        env = os.environ | {
            "TEST_CLIENT": json.dumps(client),
            "TEST_LIVE": json.dumps(live or {"attrs": {}}),
            "TEST_HELPER": str(helper),
        }
        return subprocess.run(
            ["bash", "-c", '''
                source "$TEST_HELPER"
                init_vars
                kanidm_verify_failed=0
                run() { printf '%s\n' "$*"; }
                get_oauth_app() { return 0; }
                oauth_app_type_matches() { return 0; }
                kanidm_json_cmd() { printf '%s' "$TEST_LIVE"; }
                kanidm_domain() { printf 'example.test'; }
                prune_oauth_redirect_urls_enabled() { return 1; }
                prune_oauth_scope_maps_enabled() { return 1; }
                apply_oauth_app "$TEST_CLIENT"
                verify_oauth_app "$TEST_CLIENT"
                exit "$kanidm_verify_failed"
            '''],
            env=env, text=True, capture_output=True, check=False,
        )

    def test_public_redirect_enable_disable_and_drift(self):
        client = {
            "name": "abird-agent", "displayName": "Agent", "type": "public",
            "origin": "https://example.test", "landingUrl": "https://example.test",
            "scopeMaps": {}, "pkce": True, "allowLocalhostRedirects": True,
        }
        live = {"attrs": {"oauth2_allow_localhost_redirect": ["true"]}}
        enabled = self.run_helper(client, live)
        self.assertEqual(enabled.returncode, 0, enabled.stderr)
        self.assertIn("enable-localhost-redirects abird-agent", enabled.stdout)
        self.assertIn("enable-pkce abird-agent", enabled.stdout)
        self.assertNotIn("disable-pkce", enabled.stdout)

        del client["allowLocalhostRedirects"]
        removed = self.run_helper(client, live)
        self.assertEqual(removed.returncode, 1)
        self.assertIn("disable-localhost-redirects abird-agent", removed.stdout)
        self.assertIn("localhost redirect setting differs", removed.stderr)
        self.assertEqual(self.run_helper(client).returncode, 0)
        self.assertEqual(self.run_helper(client, {
            "attrs": {"oauth2_allow_localhost_redirect": ["false"]},
        }).returncode, 0)

        client["type"] = "confidential"
        other = self.run_helper(client)
        self.assertEqual(other.returncode, 0, other.stderr)
        self.assertNotIn("localhost-redirects", other.stdout)


class AutoApplyStampTest(unittest.TestCase):
    def run_auto_apply(self, command="apply-idm", seed="stale", verify=1, login=0, apply=0):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        tmp_root = Path(os.environ.get("TMPDIR", Path.cwd() / "tmp"))
        tmp_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="kanidm-stamp-test.", dir=tmp_root) as directory:
            work = Path(directory)
            old = {"name": "fixture", "state": {"domain": {}, "oauthApps": []}}
            desired = {
                "name": "fixture",
                "state": {
                    "domain": {"displayName": "Updated domain"},
                    "oauthApps": [{"name": "abird-agent", "type": "public"}],
                },
            }
            (work / "old.json").write_text(json.dumps(old))
            (work / "desired.json").write_text(json.dumps(desired))
            (work / "password").write_text("disposable-fixture-password")
            (work / "calls").touch()
            env = os.environ | {
                "TMPDIR": str(work),
                "TEST_HELPER": str(helper),
                "TEST_WORK": str(work),
                "TEST_SEED": seed,
                "TEST_VERIFY_STATUS": str(verify),
                "TEST_LOGIN_STATUS": str(login),
                "TEST_APPLY_STATUS": str(apply),
                "KANIDM_URL": "https://example.test",
                "KANIDM_NAME": "idm_admin",
                "KANIDM_SYSTEM_NAME": "admin",
                "KANIDM_DECLARATIVE_METADATA": str(work / "desired.json"),
                "KANIDM_DECLARATIVE_STATE_DIR": str(work / "state"),
                "KANIDM_AUTO_APPLY_COMMAND": command,
                "KANIDM_AUTO_APPLY_PASSWORD_FILE": str(work / "password"),
            }
            result = subprocess.run(
                ["bash", "-c", '''
                    source "$TEST_HELPER"
                    init_vars
                    account="$kanidm_name"
                    [ "$KANIDM_AUTO_APPLY_COMMAND" != apply-system ] || account="$kanidm_system_name"
                    stamp_file="$(auto_apply_stamp_file "$KANIDM_AUTO_APPLY_COMMAND" "$account")"
                    desired_stamp="$(auto_apply_desired_stamp "$KANIDM_AUTO_APPLY_COMMAND" "$account")"
                    printf '%s' "$desired_stamp" > "$TEST_WORK/desired-stamp"
                    if [ "$TEST_SEED" = stale ]; then
                        kanidm_metadata="$TEST_WORK/old.json"
                        old_stamp="$(auto_apply_desired_stamp "$KANIDM_AUTO_APPLY_COMMAND" "$account")"
                        record_auto_apply_stamp "$stamp_file" "$old_stamp"
                        kanidm_metadata="$KANIDM_DECLARATIVE_METADATA"
                    elif [ "$TEST_SEED" = matching ]; then
                        record_auto_apply_stamp "$stamp_file" "$desired_stamp"
                    fi
                    [ ! -f "$stamp_file" ] || cp "$stamp_file" "$TEST_WORK/before-stamp"
                    wait_for_kanidm_status() { printf 'ready\n' >> "$TEST_WORK/calls"; }
                    kanidm_cmd_as() {
                        printf 'login:%s\n' "$1" >> "$TEST_WORK/calls"
                        return "$TEST_LOGIN_STATUS"
                    }
                    verify_idm() { printf 'verify\n' >> "$TEST_WORK/calls"; return "$TEST_VERIFY_STATUS"; }
                    apply_idm() { printf 'apply-idm\n' >> "$TEST_WORK/calls"; return "$TEST_APPLY_STATUS"; }
                    apply_domain() { printf 'apply-system\n' >> "$TEST_WORK/calls"; return "$TEST_APPLY_STATUS"; }
                    journalctl() { return 1; }
                    auto_apply_idm
                '''],
                env=env, text=True, capture_output=True, check=False,
            )
            before = work / "before-stamp"
            stamps = list((work / "state/auto-apply").glob("*.stamp"))
            return (
                result, (work / "calls").read_text().splitlines(),
                before.read_text().strip() if before.exists() else None,
                (work / "desired-stamp").read_text(),
                stamps[0].read_text().strip() if stamps else None,
            )

    def test_changed_declaration_is_applied_before_recording_stamp(self):
        for command, account, operations in (
            ("apply-idm", "idm_admin", ["verify", "apply-idm"]),
            ("apply-system", "admin", ["apply-system"]),
        ):
            with self.subTest(command=command):
                result, calls, before, desired, stamp = self.run_auto_apply(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(before, desired)
                self.assertEqual(calls, ["ready", f"login:{account}", *operations])
                self.assertEqual(stamp, desired)

    def test_verified_current_state_records_changed_stamp_without_apply(self):
        result, calls, before, desired, stamp = self.run_auto_apply(verify=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(before, desired)
        self.assertEqual(calls, ["ready", "login:idm_admin", "verify"])
        self.assertEqual(stamp, desired)

    def test_matching_stamp_skips_auto_apply(self):
        for command in ("apply-idm", "apply-system"):
            with self.subTest(command=command):
                result, calls, before, desired, stamp = self.run_auto_apply(command, seed="matching")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [])
                self.assertEqual(before, desired)
                self.assertEqual(stamp, desired)

    def test_first_auto_apply_records_stamp_after_success(self):
        result, calls, before, desired, stamp = self.run_auto_apply(seed="missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["ready", "login:idm_admin", "verify", "apply-idm"])
        self.assertIsNone(before)
        self.assertEqual(stamp, desired)

    def test_failed_authentication_or_apply_preserves_old_stamp(self):
        for command in ("apply-idm", "apply-system"):
            for failure in ("login", "apply"):
                with self.subTest(command=command, failure=failure):
                    result, calls, before, desired, stamp = self.run_auto_apply(command, **{failure: 23})
                    self.assertEqual(result.returncode, 23, result.stderr)
                    self.assertTrue(calls)
                    self.assertNotEqual(before, desired)
                    self.assertEqual(stamp, before)


if __name__ == "__main__":
    unittest.main()
