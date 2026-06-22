import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class NixbotScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.script = cls.repo_root / "pkgs/tools/nixbot/nixbot.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="nixbot-test.", dir=self.tmp_root))
        self.test_script = self.work_dir / "nixbot-test-source.sh"
        source = self.script.read_text(encoding="utf-8")
        self.test_script.write_text(
            source.replace('\nmain "$@"\n', "\n"),
            encoding="utf-8",
        )

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def run_script(self, body, *, check=True, env=None):
        full_env = os.environ.copy()
        full_env.update(env or {})
        return subprocess.run(
            [
                "bash",
                "-c",
                textwrap.dedent(
                    f"""
                    set -Eeuo pipefail
                    source {self.test_script}
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

    def test_argument_parsing_normalizes_modes_and_env_overrides(self):
        result = self.run_script(
            """
            init_vars
            ACTION=deploy
            normalize_host_action
            parse_args \
              --hosts 'web,db -old' \
              --group 'abird ops' \
              --goal boot \
              --build-host builder \
              --build-host-deploy-mode local-copy \
              --build-plan-jobs 2 \
              --build-jobs 3 \
              --deploy-jobs 4 \
              --verify-jobs 5 \
              --dry \
              --no-rollback \
              --no-verify \
              --prefix-host-logs \
              --log-format plain
            jq -n \
              --arg action "$ACTION" \
              --arg hostAction "$HOST_ACTION" \
              --arg hosts "$HOSTS_RAW" \
              --arg groups "$GROUPS_RAW" \
              --arg goal "$GOAL" \
              --arg buildHost "$BUILD_HOST" \
              --arg buildMode "$BUILD_HOST_DEPLOY_MODE" \
              --arg buildPlanJobs "$BUILD_PLAN_JOBS" \
              --arg buildJobs "$BUILD_JOBS" \
              --arg deployJobs "$NIXBOT_PARALLEL_JOBS" \
              --arg verifyJobs "$NIXBOT_VERIFY_JOBS" \
              --arg dry "$DRY_RUN" \
              --arg rollback "$ROLLBACK_ON_FAILURE" \
              --arg verify "$VERIFY_AFTER_DEPLOY" \
              --arg prefix "$FORCE_PREFIX_HOST_LOGS" \
              --arg logFormat "$LOG_FORMAT" \
              '{action:$action,hostAction:$hostAction,hosts:$hosts,groups:$groups,goal:$goal,buildHost:$buildHost,buildMode:$buildMode,buildPlanJobs:$buildPlanJobs,buildJobs:$buildJobs,deployJobs:$deployJobs,verifyJobs:$verifyJobs,dry:$dry,rollback:$rollback,verify:$verify,prefix:$prefix,logFormat:$logFormat}'
            """
        )

        parsed = json.loads(result.stdout)
        self.assertEqual(
            {
                "action": "deploy",
                "hostAction": "deploy",
                "hosts": "web,db -old",
                "groups": "abird ops",
                "goal": "boot",
                "buildHost": "builder",
                "buildMode": "local-copy",
                "buildPlanJobs": "2",
                "buildJobs": "3",
                "deployJobs": "4",
                "verifyJobs": "5",
                "dry": "1",
                "rollback": "0",
                "verify": "0",
                "prefix": "1",
                "logFormat": "plain",
            },
            parsed,
        )

    def test_host_selector_parsing_supports_globs_exclusions_and_implicit_all(self):
        result = self.run_script(
            """
            init_vars
            all='["abird-corp","abird-data","gap3-web","gap3-db"]'
            parse_host_selectors_json "$all" 'abird-*,-abird-data,missing*' 0
            parse_host_selectors_json "$all" '-gap3-db' 1
            """
        )

        explicit, implicit = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(
            {
                "selected": ["abird-corp", "abird-data", "missing*"],
                "excluded": ["abird-data"],
            },
            explicit,
        )
        self.assertEqual(
            {
                "selected": ["abird-corp", "abird-data", "gap3-web", "gap3-db"],
                "excluded": ["gap3-db"],
            },
            implicit,
        )

    def test_group_selection_dependency_expansion_and_ci_first_ordering(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_HOSTS_JSON='{
              "ci": {},
              "parent": {},
              "app": {"parent":"parent","deps":["db"],"target":"10.0.0.10"},
              "db": {"after":["ci"]},
              "skipped": {"skip": true}
            }'
            NIXBOT_GROUPS_JSON='{"prod":["app","skipped"]}'
            NIXBOT_GROUP_DEPENDENCY_EXCLUSIONS_JSON='{"prod":["db"]}'
            GROUPS_RAW=prod
            HOSTS_RAW=ci
            HOSTS_EXPLICIT=1
            PRIORITIZE_CI_FIRST=1
            CI_TRIGGER_HOST=ci
            resolve_selected_hosts_json '["ci","parent","app","db","skipped"]'
            """
        )

        self.assertEqual(["ci", "parent", "app", "skipped"], json.loads(result.stdout))

    def test_execution_policy_rejects_dependencies_on_skipped_or_optional_hosts(self):
        skipped = self.run_script(
            """
            init_vars
            NIXBOT_HOSTS_JSON='{"app":{"deps":["dep"]},"dep":{"skip":true}}'
            validate_selected_host_execution_policies '["app","dep"]'
            """,
            check=False,
        )
        self.assertNotEqual(0, skipped.returncode)
        self.assertIn("cannot depend on skipped host dep", skipped.stderr)

        optional = self.run_script(
            """
            init_vars
            NIXBOT_HOSTS_JSON='{"app":{"deps":["dep"]},"dep":{"deploy":"optional"}}'
            validate_selected_host_execution_policies '["app","dep"]'
            """,
            check=False,
        )
        self.assertNotEqual(0, optional.returncode)
        self.assertIn("cannot depend on non-strict deploy host dep", optional.stderr)

    def test_parent_resource_and_command_templates_have_generic_fallbacks(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE="$NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE_FALLBACK"
            NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE="$NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE_FALLBACK"
            NIXBOT_HOSTS_JSON='{"guest":{"parent":"parent","resourceId":"tenant/guest"},"plain":{}}'
            host_parent_resource_for guest
            host_parent_resource_for plain
            host_parent_reconcile_template_for guest
            host_parent_settle_template_for guest
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("tenant/guest", lines[0])
        self.assertEqual("plain", lines[1])
        self.assertIn("incus-machines-reconciler", lines[2])
        self.assertIn("incus-machines-settlement", lines[3])
        self.assertNotIn("gap3", "\n".join(lines[2:]))

    def test_group_derivation_splits_positive_groups_and_dependency_exclusions(self):
        result = self.run_script(
            """
            config='{
              "hosts": {
                "app": {"groups":["prod","web","-shared"]},
                "db": {"groups":["prod","db"]},
                "ops": {"groups":["ops","prod","-shared"]},
                "ungrouped": {}
              }
            }'
            derive_groups_json "$config"
            derive_group_dependency_exclusions_json "$config"
            """
        )

        groups, exclusions = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(
            {
                "db": ["db"],
                "ops": ["ops"],
                "prod": ["app", "db", "ops"],
                "web": ["app"],
            },
            groups,
        )
        self.assertEqual({"shared": ["app", "ops"]}, exclusions)

    def test_group_derivation_rejects_invalid_group_shapes(self):
        result = self.run_script(
            """
            derive_groups_json '{"hosts":{"bad":{"groups":"prod"}}}'
            """,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("host groups must be lists", result.stderr)

    def test_selection_helpers_filter_skipped_hosts_and_render_annotations(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_HOSTS_JSON='{
              "parent": {},
              "app": {
                "parent": "parent",
                "target": "10.0.0.10",
                "deploy": "optional",
                "wait": 7
              },
              "db": {"target": "10.0.0.11"},
              "skipped": {"skip": true}
            }'
            filter_runnable_hosts_json '["parent","app","skipped","db"]'
            bash_args_to_json_array "${FULLY_SKIPPED_HOSTS[@]}"
            emit_annotated_selected_hosts '["parent","app","skipped","db"]'
            """,
        )

        lines = result.stdout.splitlines()
        self.assertEqual(["parent", "app", "db"], json.loads(lines[0]))
        self.assertEqual(["skipped"], json.loads(lines[1]))
        self.assertEqual(
            [
                "parent (target: parent)",
                "app (target: 10.0.0.10, deploy: optional, wait: 7s, parent: parent)",
                "db (target: 10.0.0.11)",
            ],
            lines[2:],
        )

    def test_selected_host_levels_follow_dependencies_and_ci_first(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_HOSTS_JSON='{
              "ci": {},
              "parent": {},
              "db": {"after":["ci"]},
              "app": {"parent":"parent","deps":["db"]},
              "worker": {"after":["app"]}
            }'
            selected='["ci","parent","db","app","worker"]'
            selected_host_levels_json "$selected" | jq -c .
            PRIORITIZE_CI_FIRST=1
            CI_TRIGGER_HOST=ci
            selected_host_levels_json "$selected" | jq -c .
            """
        )

        normal, ci_first = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([["ci", "parent"], ["db"], ["app"], ["worker"]], normal)
        self.assertEqual([["ci"], ["parent", "db"], ["app"], ["worker"]], ci_first)

    def test_runtime_line_state_persists_marks_and_keeps_cache_in_sync(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_STATE_LOCK_TIMEOUT=1
            ensure_tmp_dir
            CACHE=''
            if line_state_mark_new seen alpha CACHE; then printf 'alpha-new\n'; fi
            if ! line_state_mark_new seen alpha CACHE; then printf 'alpha-duplicate\n'; fi
            line_state_mark seen beta CACHE
            if line_state_contains seen beta CACHE; then printf 'beta-present\n'; fi
            line_state_clear seen alpha CACHE
            if ! line_state_contains seen alpha CACHE; then printf 'alpha-cleared\n'; fi
            printf 'cache=%s\n' "$CACHE"
            cat "$(runtime_state_file seen)"
            """
        )

        self.assertEqual(
            [
                "alpha-new",
                "alpha-duplicate",
                "beta-present",
                "alpha-cleared",
                "cache=beta",
                "beta",
            ],
            result.stdout.splitlines(),
        )

    def test_active_deploy_and_activation_markers_use_hashed_runtime_paths(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            ensure_tmp_dir
            register_active_deploy app
            register_deploy_job_pid app 4242
            mark_deploy_activation_started app
            active_deploys_registered && printf 'active\n'
            deploy_jobs_started || printf 'not-started\n'
            mark_deploy_job_started
            deploy_jobs_started && printf 'started\n'
            printf '%s\n' "$(cat "$(active_deploy_registry_file app)")"
            printf '%s\n' "$(cat "$(deploy_job_registry_file 4242)")"
            printf '%s\n' "$(cat "$(deploy_activation_marker_file app)")"
            deploy_activation_unit_name app
            rollback_activation_unit_name app
            unregister_active_deploy app
            active_deploys_registered || printf 'inactive\n'
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual(
            ["active", "not-started", "started", "app", "app", "app"],
            lines[:6],
        )
        self.assertRegex(lines[6], r"^nixbot-switch-to-configuration-test\.id-[0-9a-f]{16}$")
        self.assertRegex(lines[7], r"^nixbot-rollback-to-configuration-test\.id-[0-9a-f]{16}$")
        self.assertEqual("inactive", lines[8])

    def test_build_cache_mode_resolution_uses_configured_cache_identity(self):
        result = self.run_script(
            """
            init_vars
            BUILD_HOST=builder
            BUILD_CACHE_HOST=cache-owner
            BUILD_HOST_DEPLOY_MODE=auto
            resolved_target_host_for_role() {
              case "$1" in
                builder|cache-owner) printf '10.0.0.5\n' ;;
                other) printf '10.0.0.6\n' ;;
                *) return 1 ;;
              esac
            }
            effective_build_host_deploy_mode
            BUILD_HOST=other
            effective_build_host_deploy_mode
            BUILD_HOST_DEPLOY_MODE=cache
            effective_build_host_deploy_mode
            BUILD_HOST_DEPLOY_MODE=local-copy
            effective_build_host_deploy_mode
            """
        )

        self.assertEqual(["cache", "local-copy", "cache", "local-copy"], result.stdout.splitlines())


if __name__ == "__main__":
    unittest.main()
