"""Exercise OAuth redirect policy and verified declarative auto-apply stamps."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class OAuthRedirectPolicyTest(unittest.TestCase):
    def run_helper(self, client, live=None, prune=False):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        attrs = {
            "name": [client["name"]],
            "class": ["oauth2_resource_server_public" if client["type"] == "public" else "oauth2_resource_server_basic"],
            "displayname": [client["displayName"]],
            "oauth2_rs_origin_landing": [client["landingUrl"]],
            "oauth2_rs_origin": [],
        }
        attrs.update((live or {}).get("attrs", {}))
        env = os.environ | {
            "TEST_CLIENT": json.dumps(client),
            "TEST_LIVE": json.dumps({"attrs": attrs}),
            "TEST_HELPER": str(helper),
            "TEST_PRUNE": "true" if prune else "false",
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
                prune_oauth_redirect_urls_enabled() { [ "$TEST_PRUNE" = true ]; }
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
            "origin": "https://example.test/", "landingUrl": "https://example.test/",
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

    def test_landing_origin_does_not_implicitly_broaden_exact_callback_allowlist(self):
        callback = "https://example.test/auth/oidc.callback?mode=login"
        client = {"name": "outline", "displayName": "Outline", "type": "confidential", "pkce": True,
                  "origin": "HTTPS://EXAMPLE.TEST:443", "landingUrl": "https://example.test",
                  "redirectUrls": [callback], "scopeMaps": {}}
        live = {"attrs": {"oauth2_rs_origin_landing": ["https://example.test/"], "oauth2_rs_origin": [callback]}}
        result = self.run_helper(client, live, prune=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        additions = [line for line in result.stdout.splitlines() if "add-redirect-url" in line]
        self.assertEqual(additions, ["system oauth2 add-redirect-url outline " + callback])
        self.assertNotIn("remove-redirect-url", result.stdout)
        for wrong in (callback + "/", callback.replace("mode=login", "mode=other")):
            changed = {"attrs": dict(live["attrs"], oauth2_rs_origin=[wrong])}
            result = self.run_helper(client, changed, prune=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("remove-redirect-url outline " + wrong, result.stdout)


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
                    verify_domain() { printf 'verify\n' >> "$TEST_WORK/calls"; return "$TEST_VERIFY_STATUS"; }
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
            ("apply-idm", "idm_admin", ["apply-idm"]),
            ("apply-system", "admin", ["apply-system"]),
        ):
            with self.subTest(command=command):
                result, calls, before, desired, stamp = self.run_auto_apply(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(before, desired)
                self.assertEqual(calls, ["ready", f"login:{account}", *operations])
                self.assertEqual(stamp, desired)

    def test_changed_stamp_applies_even_if_subset_verification_would_pass(self):
        result, calls, before, desired, stamp = self.run_auto_apply(verify=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(before, desired)
        self.assertEqual(calls, ["ready", "login:idm_admin", "apply-idm"])
        self.assertEqual(stamp, desired)

    def test_matching_stamp_verifies_before_skipping_writes(self):
        for command in ("apply-idm", "apply-system"):
            with self.subTest(command=command):
                result, calls, before, desired, stamp = self.run_auto_apply(command, seed="matching", verify=0)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, ["ready", "login:" + ("admin" if command == "apply-system" else "idm_admin"), "verify"])
                self.assertEqual(before, desired)
                self.assertEqual(stamp, desired)

    def test_first_auto_apply_records_stamp_after_success(self):
        result, calls, before, desired, stamp = self.run_auto_apply(seed="missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["ready", "login:idm_admin", "apply-idm"])
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

    def test_matching_stamp_drift_repairs_but_probe_failure_does_not_apply(self):
        for command in ("apply-idm", "apply-system"):
            for status in (1, 2):
                with self.subTest(command=command, status=status):
                    result, calls, before, desired, stamp = self.run_auto_apply(command, seed="matching", verify=status)
                    self.assertEqual(result.returncode, 0 if status == 1 else 2, result.stderr)
                    self.assertEqual(calls[-1], command if status == 1 else "verify")
                    self.assertEqual(stamp, before)


class OwnedStateTest(unittest.TestCase):
    # Run real verification under the conditional Bash path used by auto-apply.

    def run_fixture(self, state, live=None, ledgers=None, read_status=0, auto=False, prune=False):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        tmp_root = Path(os.environ.get("TMPDIR", Path.cwd() / "tmp"))
        tmp_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="kanidm-owned-test.", dir=tmp_root) as directory:
            work = Path(directory)
            (work / "metadata").write_text(json.dumps({"name": "fixture", "state": state}))
            (work / "password").write_text("disposable-fixture-password")
            (work / "calls").touch()
            (work / "state").mkdir()
            for suffix, content in (ledgers or {}).items():
                (work / "state" / ("fixture." + suffix)).write_text(content)
            env = os.environ | {
                "TEST_HELPER": str(helper), "TEST_WORK": str(work),
                "TEST_LIVE": json.dumps(live or {}), "TEST_READ_STATUS": str(read_status),
                "TEST_AUTO": "true" if auto else "false", "TEST_MUTATE_FIXTURE": "true" if prune else "false", "TMPDIR": str(work),
                "KANIDM_URL": "https://example.test", "KANIDM_NAME": "idm_admin",
                "KANIDM_SYSTEM_NAME": "admin", "KANIDM_DECLARATIVE_METADATA": str(work / "metadata"),
                "KANIDM_DECLARATIVE_STATE_DIR": str(work / "state"),
                "KANIDM_AUTO_APPLY_PASSWORD_FILE": str(work / "password"),
            }
            result = subprocess.run(["bash", "-c", r'''
                source "$TEST_HELPER"
                init_vars
                require_login() { return 0; }
                kanidm_json_cmd() {
                    [ "$TEST_READ_STATUS" -eq 0 ] || return "$TEST_READ_STATUS"
                    local name="${*: -1}"
                    jq -c --arg name "$name" '.[$name] // "No matching entries"' <<<"$TEST_LIVE"
                }
                scim_request() {
                    [ "$TEST_READ_STATUS" -eq 0 ] || return "$TEST_READ_STATUS"
                    case "$2" in
                        /v1/service_account) jq -c '.serviceAccounts // []' <<<"$TEST_LIVE" ;;
                        /scim/v1/Application) jq -c '.applications // {resources: []}' <<<"$TEST_LIVE" ;;
                        /scim/v1/Application/*) jq -c --arg name "${2##*/}" '.[$name] // null' <<<"$TEST_LIVE" ;;
                    esac
                }
                wait_for_kanidm_status() { return 0; }
                kanidm_cmd_as() { return 0; }
                apply_idm() { printf 'apply\n' >> "$TEST_WORK/calls"; }
                if [ "$TEST_MUTATE_FIXTURE" = true ]; then
                    run() { printf '%s\n' "$*" >> "$TEST_WORK/calls"; }
                    prune_missing_service_accounts
                    prune_missing_people
                    prune_ssh_public_keys
                    exit 0
                elif [ "$TEST_AUTO" = true ]; then
                    stamp="$(auto_apply_stamp_file apply-idm idm_admin)"
                    desired="$(auto_apply_desired_stamp apply-idm idm_admin)"
                    record_auto_apply_stamp "$stamp" "$desired"
                    cp "$stamp" "$TEST_WORK/before-stamp"
                    auto_apply_idm
                    cmp "$stamp" "$TEST_WORK/before-stamp"
                else
                    if verify_idm; then exit 0; else exit "$?"; fi
                fi
            '''], env=env, text=True, capture_output=True, check=False)
            return result, (work / "calls").read_text().splitlines()

    @staticmethod
    def person():
        return {
            "accountId": "alice", "displayName": "Alice", "legalName": "Alice Legal",
            "mail": ["alice@example.test"],
            "posix": {"enable": True, "shell": "/bin/sh", "gidNumber": 1200},
            "sshPublicKeys": {"laptop": "ssh-ed25519 AAAA desired-comment"},
        }

    @staticmethod
    def person_live():
        return {"attrs": {
            "name": ["alice"], "displayname": ["Alice"], "legalname": ["Alice Legal"],
            "mail": ["alice@example.test"], "class": ["person", "posixaccount"],
            "loginshell": ["/bin/sh"], "gidnumber": ["1200"],
            "ssh_publickey": ["laptop: ssh-ed25519 AAAA server-comment"],
        }}

    def test_person_owned_fields_and_ssh_material(self):
        person, live = self.person(), self.person_live()
        self.assertEqual(self.run_fixture({"users": [person]}, {"alice": live})[0].returncode, 0)
        for field, value in {
            "displayname": ["Other"], "legalname": ["Other"], "mail": ["other@example.test"],
            "class": ["person"], "loginshell": ["/bin/false"], "gidnumber": ["1201"],
            "ssh_publickey": ["laptop: ssh-ed25519 BBBB server-comment"],
        }.items():
            with self.subTest(field=field):
                changed = json.loads(json.dumps(live))
                changed["attrs"][field] = value
                result, _ = self.run_fixture({"users": [person]}, {"alice": changed})
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_primary_mail_is_ordered_but_secondary_mail_is_a_set(self):
        person, live = self.person(), self.person_live()
        person["mail"] += ["z@example.test", "b@example.test"]
        live["attrs"]["mail"] += ["b@example.test", "z@example.test"]
        self.assertEqual(self.run_fixture({"users": [person]}, {"alice": live})[0].returncode, 0)
        live["attrs"]["mail"] = ["b@example.test", "alice@example.test", "z@example.test"]
        self.assertEqual(self.run_fixture({"users": [person]}, {"alice": live})[0].returncode, 1)

    def test_authoritative_members_exact_but_additive_members_preserve_unowned(self):
        live = {"team": {"attrs": {"name": ["team"], "member": ["alice@example.test", "unowned@example.test"]}}}
        self.assertEqual(self.run_fixture({"groupMembers": [{"name": "team", "members": ["alice"]}]}, live)[0].returncode, 0)
        result, _ = self.run_fixture({"groups": [{"name": "team", "members": ["alice"], "mail": None, "description": None}]}, live)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("authoritative membership differs", result.stderr)

    def test_previous_managed_member_removal_verified_without_pruning_unowned(self):
        state = {"pruneGroupMembers": True, "groupMembers": [{"name": "team", "members": ["alice"]}]}
        live = {"team": {"attrs": {"name": ["team"], "member": ["alice@example.test", "bob@example.test", "unowned@example.test"]}}}
        ledger = {"group-members": "team\talice\nteam\tbob\n"}
        result, _ = self.run_fixture(state, live, ledger)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("previously managed member team/bob remains", result.stderr)
        live["team"]["attrs"]["member"].remove("bob@example.test")
        self.assertEqual(self.run_fixture(state, live, ledger)[0].returncode, 0)

    def test_removed_managed_person_group_and_key_are_verified(self):
        for suffix, state, live, diagnostic in (
            ("people", {"pruneUsers": True}, {"old": {"attrs": {"name": ["old"]}}}, "person old remains"),
            ("groups", {"pruneGroups": True}, {"old": {"attrs": {"name": ["old"]}}}, "group old remains"),
            ("ssh-public-keys", {"pruneSshPublicKeys": True}, {"alice": self.person_live()}, "SSH key alice/laptop remains"),
        ):
            with self.subTest(suffix=suffix):
                ledger = "person\talice\tlaptop\n" if suffix == "ssh-public-keys" else "old\n"
                result, _ = self.run_fixture(state, live, {suffix: ledger})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(diagnostic, result.stderr)

    def test_malformed_owned_member_or_key_response_is_not_absence(self):
        for state, live, ledger in (
            ({"pruneGroupMembers": True}, {"team": {"attrs": {"name": ["team"], "member": "wrong-shape"}}}, {"group-members": "team\tbob\n"}),
            ({"pruneSshPublicKeys": True}, {"alice": {"attrs": {"name": ["alice"], "ssh_publickey": "wrong-shape"}}}, {"ssh-public-keys": "person\talice\tlaptop\n"}),
        ):
            with self.subTest(state=state):
                result, calls = self.run_fixture(state, live, ledger, auto=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(calls, [])

    def test_failed_or_malformed_reads_stop_exact_matching_stamp_path(self):
        state = {"users": [self.person()]}
        for live, status in (
            ({"alice": self.person_live()}, 23), ({"alice": {}}, 0),
            ({"alice": {"attrs": {"name": ["alice"], "mail": "wrong-shape"}}}, 0),
        ):
            with self.subTest(live=live, status=status):
                result, calls = self.run_fixture(state, live, read_status=status, auto=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(calls, [])
        result, calls = self.run_fixture(state, {}, auto=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["apply"])

    def test_global_pruning_preserves_declared_scim_service_account(self):
        state = {"pruneServiceAccounts": True, "scimApps": [{"name": "bridge", "displayName": "Bridge", "linkedGroup": "team"}]}
        live = {"bridge": {"name": "bridge", "displayname": "Bridge", "linked_group": [{"value": "team@example.test"}]},
                "serviceAccounts": [{"attrs": {"name": ["bridge"]}}, {"attrs": {"name": ["idm_admin"]}}]}
        result, _ = self.run_fixture(state, live)
        self.assertEqual(result.returncode, 0, result.stderr)
        live["serviceAccounts"].append({"attrs": {"name": ["rogue"]}})
        self.assertEqual(self.run_fixture(state, live)[0].returncode, 1)
        live["serviceAccounts"] = "wrong-shape"
        result, _ = self.run_fixture(state, live)
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_scim_shape_or_read_failure_is_probe_failure(self):
        state = {"scimApps": [{"name": "bridge", "displayName": "Bridge", "linkedGroup": "team"}]}
        for live, status in (({"bridge": {}}, 0), ({}, 23)):
            result, calls = self.run_fixture(state, live, read_status=status, auto=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(calls, [])

    def test_builtin_accounts_survive_namespace_and_previous_ledger_pruning(self):
        state = {"pruneServiceAccounts": True, "pruneUsers": True, "pruneSshPublicKeys": True}
        live = {"serviceAccounts": [{"attrs": {"name": [name]}} for name in ("anonymous", "admin", "idm_admin")]}
        ledger = {"people": "anonymous\nadmin\nidm_admin\n", "ssh-public-keys": "service-account\tanonymous\told-key\n"}
        self.assertEqual(self.run_fixture(state, live, ledger)[0].returncode, 0)
        live["serviceAccounts"].append({"attrs": {"name": ["renamed-builtin"], "class": ["builtin"]}})
        self.assertEqual(self.run_fixture(state, live, ledger)[0].returncode, 0)
        live["serviceAccounts"].append({"attrs": {"name": ["renamed-without-marker"], "uuid": ["00000000-0000-0000-0000-ffffffffffff"]}})
        self.assertEqual(self.run_fixture(state, live, ledger)[0].returncode, 0)
        for name in ("anonymous", "admin", "idm_admin", "admin@example.test", "anonymous@example.test"):
            result, calls = self.run_fixture({"serviceAccounts": [{"accountId": name}]}, {}, auto=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(calls, [])

    def test_pruning_writes_skip_builtin_accounts_and_only_delete_owned_rogue(self):
        entries = [{"attrs": {"name": [name]}} for name in ("anonymous", "admin", "idm_admin", "rogue")]
        entries += [{"attrs": {"name": ["renamed"], "uuid": ["00000000-0000-0000-0000-ffffffffffff"]}}]
        live = {"serviceAccounts": entries, "rogue": entries[3]}
        state = {"pruneServiceAccounts": True, "pruneUsers": True, "pruneSshPublicKeys": True}
        ledgers = {"people": "anonymous\nadmin\nidm_admin\n", "ssh-public-keys": "service-account\tanonymous\told-key\n"}
        result, calls = self.run_fixture(state, live, ledgers, prune=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["service-account delete rogue"])

    def test_malformed_builtin_class_is_a_probe_failure_before_filtering(self):
        for field in ("class", "uuid"):
            live = {"serviceAccounts": [{"attrs": {"name": ["anonymous"], field: "builtin"}}]}
            result, calls = self.run_fixture({"pruneServiceAccounts": True}, live, auto=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(calls, [])

    def test_service_account_manager_is_owned(self):
        account = {"accountId": "robot", "displayName": "Robot", "entryManagedBy": "idm_admin", "mail": [], "sshPublicKeys": {}}
        live = {"robot": {"attrs": {"name": ["robot"], "displayname": ["Robot"], "entry_managed_by": ["idm_admin@example.test"]}}}
        self.assertEqual(self.run_fixture({"serviceAccounts": [account]}, live)[0].returncode, 0)
        live["robot"]["attrs"]["entry_managed_by"] = ["other@example.test"]
        self.assertEqual(self.run_fixture({"serviceAccounts": [account]}, live)[0].returncode, 1)

    def test_oauth_exact_scope_values_policy_type_and_landing_are_owned(self):
        client = {"name": "app", "displayName": "App", "type": "public", "pkce": True,
                  "origin": "https://app.example.test", "landingUrl": "https://app.example.test/home",
                  "scopeMaps": {"team": ["openid", "email"]}}
        attrs = {"name": ["app"], "class": ["oauth2_resource_server_public"], "displayname": ["App"],
                 "oauth2_rs_origin": [client["origin"] + "/"], "oauth2_rs_origin_landing": [client["landingUrl"]],
                 "oauth2_rs_scope_map": ['team@example.test: {"email", "openid"}']}
        self.assertEqual(self.run_fixture({"oauthApps": [client]}, {"app": {"attrs": attrs}})[0].returncode, 0)
        for field, value, status in (
            ("oauth2_rs_scope_map", ['team@example.test: {"email", "openid", "extra"}'], 1),
            ("oauth2_rs_scope_map", ['team@example.test: invalid-serialization'], 2),
            ("oauth2_rs_origin_landing", ["https://other.example.test"], 1),
            ("oauth2_allow_insecure_client_disable_pkce", ["true"], 1),
            ("class", ["oauth2_resource_server_basic"], 1),
        ):
            with self.subTest(field=field, value=value):
                changed = dict(attrs, **{field: value})
                result, _ = self.run_fixture({"oauthApps": [client]}, {"app": {"attrs": changed}})
                self.assertEqual(result.returncode, status, result.stderr)

    def test_invalid_metadata_is_not_empty_success(self):
        for state in ({"users": "invalid"}, {"pruneUsers": "true"}):
            result, _ = self.run_fixture(state, {})
            self.assertEqual(result.returncode, 2, result.stderr)

class TransportBoundTest(unittest.TestCase):
    def test_cached_domain_stamp_validates_singleton_collection_before_writes(self):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        tmp_root = Path(os.environ.get("TMPDIR", Path.cwd() / "tmp"))
        tmp_root.mkdir(parents=True, exist_ok=True)
        # Exact upstream /v1/domain response is Vec<Entry>, not a single Entry.
        valid = {"attrs": {"domain_display_name": ["Desired"]}}
        for response, expected_status, writes in (
            ([valid], 0, False),
            ([{"attrs": {"domain_display_name": ["Old"]}}], 0, True),
            ([], 2, False), ([valid, valid], 2, False), (valid, 2, False),
            ([{"attrs": {"domain_display_name": [42]}}], 2, False),
            ([{"attrs": {"domain_display_name": "Desired"}}], 2, False),
            ([{"attrs": {"other": ["value"]}}], 2, False),
        ):
            with self.subTest(response=response), tempfile.TemporaryDirectory(prefix="kanidm-domain-test.", dir=tmp_root) as directory:
                work = Path(directory)
                (work / "metadata").write_text(json.dumps({"name": "fixture", "state": {"domain": {"displayName": "Desired"}}}))
                (work / "password").write_text("disposable-fixture-password")
                result = subprocess.run(["bash", "-c", r'''
                    source "$TEST_HELPER"
                    init_vars
                    wait_for_kanidm_status() { return 0; }
                    kanidm_cmd_as() { return 0; }
                    scim_request() { printf '%s' "$TEST_DOMAIN"; }
                    apply_domain() { touch "$TEST_WORK/write"; }
                    stamp="$(auto_apply_stamp_file apply-system admin)"
                    record_auto_apply_stamp "$stamp" "$(auto_apply_desired_stamp apply-system admin)"
                    cp "$stamp" "$TEST_WORK/before-stamp"
                    auto_apply_idm
                '''], env=os.environ | {
                    "TEST_HELPER": str(helper), "TEST_WORK": str(work), "TMPDIR": str(work),
                    "TEST_DOMAIN": json.dumps(response),
                    "KANIDM_URL": "https://example.test", "KANIDM_SYSTEM_NAME": "admin",
                    "KANIDM_DECLARATIVE_METADATA": str(work / "metadata"),
                    "KANIDM_DECLARATIVE_STATE_DIR": str(work / "state"),
                    "KANIDM_AUTO_APPLY_PASSWORD_FILE": str(work / "password"),
                    "KANIDM_AUTO_APPLY_COMMAND": "apply-system",
                }, text=True, capture_output=True)
                self.assertEqual(result.returncode, expected_status, result.stderr)
                self.assertEqual((work / "write").exists(), writes)
                self.assertEqual(next((work / "state/auto-apply").glob("*.stamp")).read_text(), (work / "before-stamp").read_text())

    def test_http_calls_and_readiness_budget_are_bounded(self):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        result = subprocess.run(["bash", "-c", r'''
            source "$TEST_HELPER"
            init_vars
            kanidm_url=https://example.test
            KANIDM_AUTO_APPLY_WAIT_SECONDS=5
            curl() { printf '%s\n' "$*" >&2; SECONDS=10000; return 28; }
            if wait_for_kanidm_status; then exit 8; fi
            kanidm_bearer_token() { printf disposable-fixture-token; }
            if scim_request GET /v1/domain; then exit 9; fi
        '''], env=os.environ | {"TEST_HELPER": str(helper)}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        requests = [line for line in result.stderr.splitlines() if line.startswith("--")]
        self.assertEqual(len(requests), 2, result.stderr)
        self.assertIn("--connect-timeout 5 --max-time 5", requests[0])
        self.assertIn("--connect-timeout 5 --max-time 30", requests[1])
        self.assertIn("not ready within 5 seconds", result.stderr)

    def test_cli_calls_have_a_total_timeout(self):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        result = subprocess.run(["bash", "-c", r'''
            source "$TEST_HELPER"
            init_vars
            timeout() { printf '%s\n' "$*"; return 124; }
            kanidm_cmd_as fixture person list
        '''], env=os.environ | {"TEST_HELPER": str(helper)}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(result.stdout.startswith("--kill-after=5s 60s kanidm "), result.stdout)

    def test_image_fingerprint_matches_upstream_bytes(self):
        import hashlib
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        tmp_root = Path(os.environ.get("TMPDIR", Path.cwd() / "tmp"))
        tmp_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="kanidm-image-test.", dir=tmp_root) as directory:
            for extension, discriminator in (("png", 0), ("jpg", 1), ("gif", 2), ("svg", 3), ("webp", 4)):
                with self.subTest(extension=extension):
                    image = Path(directory) / ("fixture." + extension)
                    image.write_bytes(b"fixture payload")
                    result = subprocess.run(["bash", "-c", 'source "$TEST_HELPER"; oauth_image_fingerprint "$TEST_IMAGE"'],
                        env=os.environ | {"TEST_HELPER": str(helper), "TEST_IMAGE": str(image)}, text=True, capture_output=True)
                    expected = hashlib.sha256(image.name.encode() + bytes([discriminator]) + image.read_bytes()).hexdigest()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)

class ApplyConvergenceTest(unittest.TestCase):
    def test_failed_post_apply_verification_preserves_ledger_and_stamp(self):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        tmp_root = Path(os.environ.get("TMPDIR", Path.cwd() / "tmp"))
        tmp_root.mkdir(parents=True, exist_ok=True)
        for read_status in (0, 23):
            with self.subTest(read_status=read_status), tempfile.TemporaryDirectory(prefix="kanidm-apply-test.", dir=tmp_root) as directory:
                work = Path(directory)
                (work / "metadata").write_text(json.dumps({"name": "fixture", "state": {"users": [OwnedStateTest.person()]}}))
                (work / "password").write_text("disposable-fixture-password")
                (work / "state").mkdir()
                (work / "state/fixture.people").write_text("previous-owner\n")
                env = os.environ | {
                    "TEST_HELPER": str(helper), "TEST_WORK": str(work), "TEST_READ_STATUS": str(read_status),
                    "KANIDM_URL": "https://example.test", "KANIDM_NAME": "idm_admin",
                    "KANIDM_DECLARATIVE_METADATA": str(work / "metadata"),
                    "KANIDM_DECLARATIVE_STATE_DIR": str(work / "state"),
                    "KANIDM_AUTO_APPLY_PASSWORD_FILE": str(work / "password"), "TMPDIR": str(work),
                }
                result = subprocess.run(["bash", "-c", r'''
                    source "$TEST_HELPER"
                    init_vars
                    require_login() { return 0; }
                    wait_for_kanidm_status() { return 0; }
                    kanidm_cmd_as() { return 0; }
                    apply_person() { printf 'write-attempt\n' > "$TEST_WORK/writes"; }
                    kanidm_json_cmd() {
                        [ "$TEST_READ_STATUS" -eq 0 ] || return "$TEST_READ_STATUS"
                        printf '%s' '{"attrs":{"name":["alice"],"displayname":["Wrong display name"]}}'
                    }
                    stamp="$(auto_apply_stamp_file apply-idm idm_admin)"
                    record_auto_apply_stamp "$stamp" original-stamp
                    auto_apply_idm
                '''], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 1 if read_status == 0 else 2, result.stderr)
                self.assertTrue((work / "writes").exists())
                self.assertEqual((work / "state/fixture.people").read_text(), "previous-owner\n")
                self.assertEqual(next((work / "state/auto-apply").glob("*.stamp")).read_text().strip(), "original-stamp")

    def test_oauth_type_mismatch_does_not_delete_existing_grants(self):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        result = subprocess.run(["bash", "-c", r'''
            source "$TEST_HELPER"
            init_vars
            get_oauth_app() { return 0; }
            oauth_app_type_matches() { return 1; }
            run() { printf 'unexpected-mutation\n'; }
            apply_oauth_app '{"name":"app","displayName":"App","type":"public","origin":"https://example.test","landingUrl":"https://example.test","pkce":true}'
        '''], env=os.environ | {"TEST_HELPER": str(helper)}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("unexpected-mutation", result.stdout)

class ServiceAccountFieldUpdateTest(unittest.TestCase):
    def run_fixture(self, desired=None, attrs=None, deny_manager=False, missing=False, read_status=0):
        helper = Path(__file__).resolve().parents[1] / "helper.sh"
        account = desired or {"accountId": "robot", "displayName": "Robot", "entryManagedBy": "idm_admin", "mail": [], "sshPublicKeys": {}}
        attributes = {"name": ["robot"], "displayname": ["Robot"], "entry_managed_by": ["idm_admin@example.test"]}
        attributes.update(attrs or {})
        tmp_root = Path(os.environ.get("TMPDIR", Path.cwd() / "tmp"))
        tmp_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="kanidm-account-update-test.", dir=tmp_root) as directory:
            work = Path(directory)
            (work / "calls").touch()
            result = subprocess.run(["bash", "-c", r'''
                source "$TEST_HELPER"
                init_vars
                kanidm_json_cmd() {
                    [ "$TEST_READ_STATUS" -eq 0 ] || return "$TEST_READ_STATUS"
                    if [ "$TEST_MISSING" = true ] && [ ! -f "$TEST_WORK/created" ]; then
                        printf '%s' '"No matching entries"'
                    else printf '%s' "$TEST_LIVE"; fi
                }
                kanidm_cmd() {
                    printf '%s\n' "$*" >> "$TEST_WORK/calls"
                    if [ "$TEST_DENY_MANAGER" = true ] && [[ " $* " == *" --entry-managed-by "* ]]; then
                        printf 'AccessDenied (fixture)\n' >&2
                        return 23
                    fi
                    [ "$1 $2" != 'service-account create' ] || touch "$TEST_WORK/created"
                    return 0
                }
                apply_service_account "$TEST_ACCOUNT"
            '''], env=os.environ | {
                "TEST_HELPER": str(helper), "TEST_WORK": str(work),
                "TEST_ACCOUNT": json.dumps(account), "TEST_LIVE": json.dumps({"attrs": attributes}),
                "TEST_DENY_MANAGER": "true" if deny_manager else "false",
                "TEST_MISSING": "true" if missing else "false", "TEST_READ_STATUS": str(read_status),
            }, text=True, capture_output=True)
            return result, (work / "calls").read_text().splitlines()

    def test_converged_metadata_and_keys_make_no_writes(self):
        account = {"accountId": "robot", "displayName": "Robot", "entryManagedBy": "idm_admin", "mail": ["primary@example.test", "z@example.test", "a@example.test"],
                   "sshPublicKeys": {"laptop": "ssh-ed25519 AAAA desired-comment"}}
        result, calls = self.run_fixture(account, {"mail": ["primary@example.test", "a@example.test", "z@example.test"],
            "ssh_publickey": ["laptop: ssh-ed25519 AAAA server-comment"]}, deny_manager=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        result, calls = self.run_fixture(attrs={"mail": ["unowned@example.test"]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_display_drift_does_not_request_manager_write(self):
        result, calls = self.run_fixture(attrs={"displayname": ["Old"]}, deny_manager=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["service-account update robot --displayname Robot"])

    def test_genuine_manager_drift_propagates_denial(self):
        result, calls = self.run_fixture(attrs={"entry_managed_by": ["other@example.test"]}, deny_manager=True)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(calls, ["service-account update robot --entry-managed-by idm_admin"])
        self.assertIn("AccessDenied", result.stderr)

    def test_creation_does_not_reassign_manager_again(self):
        result, calls = self.run_fixture(missing=True, deny_manager=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["service-account create robot Robot idm_admin"])

    def test_owned_mail_or_key_drift_only_writes_changed_fields(self):
        account = {"accountId": "robot", "displayName": "Robot", "entryManagedBy": "idm_admin", "mail": ["new@example.test"], "sshPublicKeys": {"laptop": "ssh-ed25519 AAAA"}}
        result, calls = self.run_fixture(account, {"mail": ["old@example.test"], "ssh_publickey": ["laptop: ssh-ed25519 BBBB"]}, deny_manager=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["service-account update robot --mail new@example.test",
                                "service-account ssh delete-publickey robot laptop",
                                "service-account ssh add-publickey robot laptop ssh-ed25519 AAAA"])

    def test_failed_account_probe_does_not_write(self):
        for attrs, read_status in (({}, 23), ({"entry_managed_by": "invalid-shape"}, 0)):
            result, calls = self.run_fixture(attrs=attrs, read_status=read_status)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
