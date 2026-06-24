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

    def test_cleanup_removes_success_runtime_and_empty_diag_dirs(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_DIAG_KEEP_ROOT={self.work_dir / "diag-keep"}
            ensure_tmp_dir
            runtime_dir="$RUNTIME_WORK_DIR"
            diag_dir="$NIXBOT_DIAG_DIR"
            cleanup
            [ ! -e "$runtime_dir" ] && printf 'runtime-gone\n'
            [ ! -e "$diag_dir" ] && printf 'diag-gone\n'
            [ ! -e "$NIXBOT_DIAG_KEEP_ROOT" ] && printf 'keep-root-gone\n'
            """
        )

        self.assertEqual(
            ["runtime-gone", "diag-gone", "keep-root-gone"],
            result.stdout.splitlines(),
        )

    def test_cleanup_discards_empty_kept_diag_dir(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_DIAG_KEEP_ROOT={self.work_dir / "diag-keep"}
            ensure_tmp_dir
            runtime_dir="$RUNTIME_WORK_DIR"
            diag_dir="$NIXBOT_DIAG_DIR"
            NIXBOT_KEEP_DIAG_DIR=1
            cleanup
            [ ! -e "$runtime_dir" ] && printf 'runtime-gone\n'
            [ ! -e "$diag_dir" ] && printf 'diag-gone\n'
            [ ! -e "$NIXBOT_DIAG_KEEP_ROOT" ] && printf 'keep-root-gone\n'
            """
        )

        self.assertEqual(
            ["runtime-gone", "diag-gone", "keep-root-gone"],
            result.stdout.splitlines(),
        )
        self.assertNotIn("Logs kept at:", result.stderr)

    def test_cleanup_preserves_nonempty_kept_diag_dir(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_DIAG_KEEP_ROOT={self.work_dir / "diag-keep"}
            ensure_tmp_dir
            runtime_dir="$RUNTIME_WORK_DIR"
            diag_name="$(basename "$NIXBOT_DIAG_DIR")"
            printf 'failure log\n' >"$NIXBOT_DIAG_DIR/failure.log"
            NIXBOT_KEEP_DIAG_DIR=1
            cleanup
            [ ! -e "$runtime_dir" ] && printf 'runtime-gone\n'
            [ -f "$NIXBOT_DIAG_KEEP_ROOT/$diag_name/failure.log" ] && printf 'diag-kept\n'
            cat "$NIXBOT_DIAG_KEEP_ROOT/$diag_name/failure.log"
            """
        )

        self.assertEqual(
            ["runtime-gone", "diag-kept", "failure log"],
            result.stdout.splitlines(),
        )
        self.assertIn("Logs kept at:", result.stderr)

    def test_cleanup_continues_after_best_effort_helper_failure(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_DIAG_KEEP_ROOT={self.work_dir / "diag-keep"}
            ensure_tmp_dir
            runtime_dir="$RUNTIME_WORK_DIR"
            cleanup_repo_worktree() {{ return 1; }}
            cleanup
            [ ! -e "$runtime_dir" ] && printf 'runtime-gone\n'
            """
        )

        self.assertEqual(["runtime-gone"], result.stdout.splitlines())

    def test_cleanup_preserves_errexit_for_direct_callers(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_DIAG_KEEP_ROOT={self.work_dir / "diag-keep"}
            ensure_tmp_dir
            cleanup
            case "$-" in
              *e*) printf 'errexit-on\n' ;;
              *) printf 'errexit-off\n' ;;
            esac
            """
        )

        self.assertEqual(["errexit-on"], result.stdout.splitlines())

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

    def test_rollback_host_to_snapshot_command_and_transport_failure_verification(self):
        cmd_file = self.work_dir / "rollback-cmd"
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            prepare_deploy_context() {{ return 0; }}
            wait_for_in_flight_deploy_activation() {{ return 0; }}
            print_deploy_systemd_user_manager_report() {{ return 0; }}
            report_activation_lock_contention_if_present() {{ return 0; }}
            host_boot_is_container() {{ return 1; }}
            run_with_combined_stream_capture() {{
              local -n out_ref="$1"
              shift
              printf '%s\n' "$2" >{cmd_file}
              out_ref='transport closed'
              return 37
            }}
            verify_rollback_target_state() {{
              printf 'verify:%s:%s\n' "$1" "$2"
              return "$VERIFY_ROLLBACK_RC"
            }}
            set +e
            VERIFY_ROLLBACK_RC=0
            rollback_host_to_snapshot app '/nix/store/snapshot path'
            printf 'verified-rc:%s\n' "$?"
            VERIFY_ROLLBACK_RC=1
            rollback_host_to_snapshot app '/nix/store/snapshot path'
            printf 'failed-rc:%s\n' "$?"
            set -e
            cat {cmd_file}
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("verify:app:/nix/store/snapshot path", lines[0])
        self.assertEqual("verified-rc:0", lines[1])
        self.assertEqual("verify:app:/nix/store/snapshot path", lines[2])
        self.assertEqual("failed-rc:37", lines[3])
        command = lines[4]
        self.assertIn("NIXOS_INSTALL_BOOTLOADER=0 systemd-run", command)
        self.assertIn("--wait --collect --no-ask-password --pipe --quiet", command)
        self.assertIn("--service-type=exec", command)
        self.assertRegex(command, r"--unit=nixbot-rollback-to-configuration-test\.id-[0-9a-f]{16}")
        self.assertIn("/run/current-system/sw/bin/bash -c", command)
        self.assertIn("/run/current-system/sw/bin/base64\\ -d", command)
        self.assertIn("nixbot-activation", command)
        self.assertNotIn(" -lc ", command)
        self.assertNotIn("$'", command)


    def test_wait_for_in_flight_deploy_activation_waits_then_proceeds(self):
        count_file = self.work_dir / "call-count"
        result = self.run_script(
            f"""
            init_vars
            NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS=1200
            NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS=180
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            : >{count_file}
            deploy_activation_unit_state() {{
              local n
              n=$(($(cat {count_file}) + 1))
              printf '%s' "$n" >{count_file}
              if [ "$n" -lt 3 ]; then
                printf 'active'
              else
                printf 'inactive'
              fi
              return 0
            }}
            sleep_for_retry_or_signal() {{ return 0; }}
            set +e
            wait_for_in_flight_deploy_activation app
            printf 'wait-rc:%s\n' "$?"
            set -e
            printf 'calls:%s\n' "$(cat {count_file})"
            """
        )
        lines = result.stdout.splitlines()
        self.assertEqual("wait-rc:0", lines[-2])
        self.assertEqual("calls:3", lines[-1])
        self.assertIn("waiting for in-flight deploy activation", result.stderr)
        self.assertIn("in-flight deploy activation settled", result.stderr)

    def test_wait_for_in_flight_deploy_activation_proceeds_when_unit_absent(self):
        result = self.run_script(
            f"""
            init_vars
            NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS=1200
            NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS=180
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            deploy_activation_unit_state() {{ printf ''; return 0; }}
            sleep_for_retry_or_signal() {{ return 0; }}
            set +e
            wait_for_in_flight_deploy_activation app
            printf 'wait-rc:%s\n' "$?"
            set -e
            """
        )
        lines = result.stdout.splitlines()
        self.assertEqual("wait-rc:0", lines[-1])

    def test_nixbot_activation_command_promotes_profile_after_successful_switch(self):
        result = self.run_script(
            """
            init_vars
            nixbot_activation_command '/nix/store/system path' switch 1 boot
            """
        )

        command = result.stdout
        switch_index = command.index('NIXOS_INSTALL_BOOTLOADER=0 "${system_path}/bin/switch-to-configuration" "${goal}"')
        profile_index = command.index('"${nix_env_path}" -p /nix/var/nix/profiles/system --set')
        boot_index = command.index('NIXOS_INSTALL_BOOTLOADER=1 "${system_path}/bin/switch-to-configuration" "${post_promote_bootloader_goal}"')
        self.assertLess(switch_index, profile_index)
        self.assertLess(profile_index, boot_index)
        self.assertIn("post_promote_bootloader_goal=boot", command)
        self.assertIn('nix_env_path="${system_path}/sw/bin/nix-env"', command)
        self.assertIn('system path is missing nix-env: ${nix_env_path}', command)

    def test_nixbot_activation_command_skips_bootloader_for_containers(self):
        result = self.run_script(
            """
            init_vars
            nixbot_activation_command '/nix/store/container system' switch 1 ''
            """
        )

        command = result.stdout
        self.assertIn('NIXOS_INSTALL_BOOTLOADER=0 "${system_path}/bin/switch-to-configuration" "${goal}"', command)
        self.assertIn('"${nix_env_path}" -p /nix/var/nix/profiles/system --set', command)
        self.assertIn("post_promote_bootloader_goal=''", command)
        self.assertIn('if [ -n "${post_promote_bootloader_goal}" ]; then', command)

    def test_nixbot_activation_runner_decodes_script_without_login_shell(self):
        fake_system = self.work_dir / "fake system"
        result = self.run_script(
            f"""
            init_vars
            mkdir -p "{fake_system}/bin"
            touch "{fake_system}/nixos-version"
            cat >"{fake_system}/bin/switch-to-configuration" <<'EOF_SWITCH'
#!/usr/bin/env bash
printf 'switched:%s\n' "$1"
EOF_SWITCH
            chmod +x "{fake_system}/bin/switch-to-configuration"
            script="$(nixbot_activation_command "{fake_system}" test 0 '')"
            runner="$(nixbot_activation_runner_command "$script")"
            printf 'runner:%s\n' "$runner"
            eval "$runner"
            """
        )

        lines = result.stdout.splitlines()
        self.assertIn("/run/current-system/sw/bin/bash -c", lines[0])
        self.assertIn("/run/current-system/sw/bin/base64\\ -d", lines[0])
        self.assertIn("nixbot-activation", lines[0])
        self.assertNotIn(" -lc ", lines[0])
        self.assertNotIn("$'", lines[0])
        self.assertEqual("switched:test", lines[1])

    def test_host_boot_is_container_evaluates_boolean_as_json(self):
        result = self.run_script(
            """
            init_vars
            run_supervised_stdout_capture() {
              local -n out_ref="$1"
              shift 2
              printf 'args:%s\n' "$*"
              case " $* " in
                *" --json "*) ;;
                *) echo "missing --json" >&2; return 2 ;;
              esac
              case " $* " in
                *" --raw "*) echo "unexpected --raw" >&2; return 2 ;;
              esac
              out_ref="${BOOT_IS_CONTAINER}"
              return 0
            }

            set +e
            BOOT_IS_CONTAINER=false
            host_boot_is_container pvl-l5
            printf 'false-rc:%s\n' "$?"
            BOOT_IS_CONTAINER=true
            host_boot_is_container pvl-lxc
            printf 'true-rc:%s\n' "$?"
            set -e
            """
        )

        lines = result.stdout.splitlines()
        self.assertIn("--json", lines[0])
        self.assertIn("--option warn-dirty false", lines[0])
        self.assertNotIn("--raw", lines[0])
        self.assertEqual("false-rc:1", lines[1])
        self.assertIn("--json", lines[2])
        self.assertIn("--option warn-dirty false", lines[2])
        self.assertNotIn("--raw", lines[2])
        self.assertEqual("true-rc:0", lines[3])

    def test_activation_post_promote_bootloader_goal_is_contained(self):
        result = self.run_script(
            """
            init_vars
            host_boot_is_container() {
              case "$1" in
                physical) return 1 ;;
                container) return 0 ;;
                *) echo "unexpected container eval" >&2; return 2 ;;
              esac
            }
            printf 'physical:%s\n' "$(activation_post_promote_bootloader_goal physical switch)"
            printf 'container:%s\n' "$(activation_post_promote_bootloader_goal container switch)"
            printf 'test:%s\n' "$(activation_post_promote_bootloader_goal unexpected test)"
            """
        )

        self.assertEqual(
            ["physical:boot", "container:", "test:"],
            result.stdout.splitlines(),
        )
        self.assertNotIn("unexpected container eval", result.stderr)

    def test_read_snapshot_system_path_file_extracts_single_system_path(self):
        snapshot_file = self.work_dir / "snapshot.path"
        result = self.run_script(
            f"""
            init_vars
            printf '%s\n%s\n' \
              "warning: Git tree '/tmp/repo' is dirty" \
              "/nix/store/h6ai32lqbrwmlkn8qv79cq0xbns8s801-nixos-system-pvl-l5-26.05" \
              >{snapshot_file}
            read_snapshot_system_path_file {snapshot_file}

            printf '%s\n%s\n' \
              "/nix/store/h6ai32lqbrwmlkn8qv79cq0xbns8s801-nixos-system-pvl-l5-26.05" \
              "/nix/store/215y4cfg0phxmd9m0bdiz6wa5zpqyac5-nixos-system-pvl-x2-26.05" \
              >{snapshot_file}
            set +e
            read_snapshot_system_path_file {snapshot_file}
            printf 'multi-rc:%s\n' "$?"
            set -e
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual(
            "/nix/store/h6ai32lqbrwmlkn8qv79cq0xbns8s801-nixos-system-pvl-l5-26.05",
            lines[0],
        )
        self.assertEqual("multi-rc:1", lines[1])

    def test_parent_readiness_fast_success_summarizes_per_parent(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_PARENT_READINESS_SLOW_SECS=10
            host_parent_for() { printf 'parent'; }
            host_parent_resource_for() { printf '%s' "${1#abird-}"; }
            host_parent_reconcile_template_for() { printf 'reconcile{resourceArgs}'; }
            host_parent_settle_template_for() { printf 'settle{resourceArgs}'; }
            prepare_deploy_context() { return 0; }
            retry_transport_command() { return 0; }
            ensure_deploy_wave_parent_readiness abird-ci abird-corp
            """
        )

        self.assertIn("--- Parent Readiness: parent ---", result.stderr)
        self.assertIn("[parent-readiness] parent: ok (0s)", result.stderr)
        self.assertNotIn("starting reconcile", result.stderr)
        self.assertNotIn("reconcile ok for", result.stderr)
        self.assertNotIn("ci, corp", result.stderr)

    def test_parent_readiness_slow_success_expands_phase_detail(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_PARENT_READINESS_SLOW_SECS=0
            retry_transport_command() { return 0; }
            run_named_prepared_root_command reconcile parent "ci, corp" true
            """
        )

        self.assertIn("[parent-readiness] parent: reconcile ok for ci, corp after 0s", result.stderr)

    def test_parent_readiness_failure_keeps_phase_and_resources(self):
        result = self.run_script(
            """
            init_vars
            retry_transport_command() { return 7; }
            set +e
            run_named_prepared_root_command settle parent "ci, corp" false
            printf 'rc:%s\n' "$?"
            set -e
            """
        )

        self.assertEqual(["rc:7"], result.stdout.splitlines())
        self.assertIn("[parent-readiness] parent: settle failed for ci, corp after 0s", result.stderr)

    def test_build_plan_cache_miss_progress_is_concise(self):
        result = self.run_script(
            """
            init_vars
            read_cached_host_build_plan() { return 1; }
            eval_host_build_plan_drv_path() { printf '/nix/store/app.drv\\n'; }
            write_cached_host_build_plan() { return 0; }
            resolve_host_build_plan_drv_path app
            """
        )

        self.assertEqual(["/nix/store/app.drv"], result.stdout.splitlines())
        self.assertIn("Evaluating..", result.stderr)
        self.assertNotIn("Evaluating build plan for app", result.stderr)

    def test_activate_prepared_system_path_uses_transient_unit_command_shape(self):
        cmd_file = self.work_dir / "activate-cmd"
        result = self.run_script(
            f"""
            init_vars
            GOAL=boot
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            host_boot_is_container() {{ return 1; }}
            run_with_combined_stream_capture() {{
              local -n out_ref="$1"
              shift
              printf '%s\n' "$2" >{cmd_file}
              out_ref=''
              return 0
            }}
            activate_prepared_system_path app '/nix/store/system path'
            printf 'activate-rc:%s\n' "$?"
            cat {cmd_file}
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("activate-rc:0", lines[0])
        command = lines[1]
        self.assertIn("NIXOS_INSTALL_BOOTLOADER=0 systemd-run", command)
        self.assertIn("-E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER -E NIXOS_NO_CHECK", command)
        self.assertIn("--property=RuntimeMaxSec=", command)
        self.assertIn("--property=TimeoutStopSec=", command)
        self.assertIn("--property=KillMode=control-group", command)
        self.assertIn("--property=CollectMode=inactive-or-failed", command)
        self.assertRegex(command, r"--unit=nixbot-switch-to-configuration-test\.id-[0-9a-f]{16}")
        self.assertIn("/run/current-system/sw/bin/bash -c", command)
        self.assertIn("/run/current-system/sw/bin/base64\\ -d", command)
        self.assertIn("nixbot-activation", command)
        self.assertNotIn(" -lc ", command)
        self.assertNotIn("$'", command)

    def test_activate_prepared_system_path_disables_bootloader_for_containers(self):
        cmd_file = self.work_dir / "activate-container-cmd"
        result = self.run_script(
            f"""
            init_vars
            GOAL=switch
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            host_boot_is_container() {{ return 0; }}
            run_with_combined_stream_capture() {{
              local -n out_ref="$1"
              shift
              printf '%s\n' "$2" >{cmd_file}
              out_ref=''
              return 0
            }}
            activate_prepared_system_path app '/nix/store/system path'
            printf 'activate-rc:%s\n' "$?"
            cat {cmd_file}
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("activate-rc:0", lines[0])
        command = lines[1]
        self.assertIn("NIXOS_INSTALL_BOOTLOADER=0 systemd-run", command)
        self.assertIn("/run/current-system/sw/bin/bash -c", command)
        self.assertIn("/run/current-system/sw/bin/base64\\ -d", command)
        self.assertIn("nixbot-activation", command)
        self.assertNotIn(" -lc ", command)
        self.assertNotIn("$'", command)

    def test_activate_prepared_system_path_does_not_persist_test_goal(self):
        cmd_file = self.work_dir / "activate-test-cmd"
        result = self.run_script(
            f"""
            init_vars
            GOAL=test
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            host_boot_is_container() {{
              echo "unexpected container eval" >&2
              return 2
            }}
            run_with_combined_stream_capture() {{
              local -n out_ref="$1"
              shift
              printf '%s\n' "$2" >{cmd_file}
              out_ref=''
              return 0
            }}
            activate_prepared_system_path app '/nix/store/system path'
            printf 'activate-rc:%s\n' "$?"
            cat {cmd_file}
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("activate-rc:0", lines[0])
        command = lines[1]
        self.assertIn("NIXOS_INSTALL_BOOTLOADER=0 systemd-run", command)
        self.assertIn("/run/current-system/sw/bin/bash -c", command)
        self.assertIn("/run/current-system/sw/bin/base64\\ -d", command)
        self.assertIn("nixbot-activation", command)
        self.assertNotIn(" -lc ", command)
        self.assertNotIn("$'", command)
        self.assertNotIn("unexpected container eval", result.stderr)

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

    def test_transport_retry_policy_and_backoff_are_narrow(self):
        result = self.run_script(
            """
            init_vars
            for rc in 124 255 1 2 130 143; do
              if transport_status_is_retryable "$rc"; then
                printf '%s=retry\n' "$rc"
              else
                printf '%s=stop\n' "$rc"
              fi
            done
            NIXBOT_TRANSPORT_RETRY_DELAY_SECS=7
            transport_retry_backoff_seconds 1
            transport_retry_backoff_seconds 2
            transport_retry_backoff_seconds 3
            primary_probe_failure_is_temporary_transport 'ssh: connect to host 10.0.0.1 port 22: Connection timed out' && printf 'timeout=temporary\n'
            primary_probe_failure_is_temporary_transport 'kex_exchange_identification: Connection closed by remote host' && printf 'kex=temporary\n'
            primary_probe_failure_is_temporary_transport 'switch-to-configuration failed' || printf 'activation=permanent\n'
            """
        )

        self.assertEqual(
            [
                "124=retry",
                "255=retry",
                "1=stop",
                "2=stop",
                "130=stop",
                "143=stop",
                "0",
                "7",
                "14",
                "timeout=temporary",
                "kex=temporary",
                "activation=permanent",
            ],
            result.stdout.splitlines(),
        )

    def test_retry_transport_command_retries_ssh_failures_and_stops_on_permanent_failures(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_TRANSPORT_RETRY_ATTEMPTS=3
            NIXBOT_TRANSPORT_RETRY_DELAY_SECS=1
            sleep() { printf 'sleep:%s\n' "$1"; }
            retry_hook() { printf 'hook\n'; }
            attempts=0
            flaky_ssh() {
              attempts=$((attempts + 1))
              printf 'attempt:%s\n' "$attempts"
              [ "$attempts" -ge 3 ] && return 0
              return 255
            }
            retry_transport_command 'SSH probe for app' retry_hook flaky_ssh
            printf 'final-attempts:%s\n' "$attempts"

            attempts=0
            permanent_failure() {
              attempts=$((attempts + 1))
              printf 'permanent-attempt:%s\n' "$attempts"
              return 1
            }
            set +e
            retry_transport_command 'Activation for app' retry_hook permanent_failure
            rc=$?
            set -e
            printf 'permanent-rc:%s attempts:%s\n' "$rc" "$attempts"
            """,
        )

        self.assertEqual(
            [
                "attempt:1",
                "sleep:1",
                "hook",
                "attempt:2",
                "sleep:2",
                "hook",
                "attempt:3",
                "final-attempts:3",
                "permanent-attempt:1",
                "permanent-rc:1 attempts:1",
            ],
            result.stdout.splitlines(),
        )
        self.assertIn("SSH probe for app transport unavailable; retrying (2/3) in 1s", result.stderr)
        self.assertIn("SSH probe for app transport unavailable; retrying (3/3) in 2s", result.stderr)
        self.assertNotIn("Activation for app transport unavailable", result.stderr)

    def test_primary_probe_retries_ssh_transport_and_clears_control_master(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_TRANSPORT_RETRY_ATTEMPTS=3
            NIXBOT_TRANSPORT_RETRY_DELAY_SECS=1
            sleep() { printf 'sleep:%s\n' "$1"; }
            clear_control_master_socket() { printf 'clear:%s:%s\n' "$1" "$2"; }
            attempts=0
            run_supervised_combined_capture() {
              local -n output_ref="$1"
              shift
              attempts=$((attempts + 1))
              printf 'probe:%s:%s\n' "$attempts" "$*"
              if [ "$attempts" -lt 2 ]; then
                output_ref='Connection reset by peer'
                return 255
              fi
              output_ref=''
              return 0
            }
            probe_primary_deploy_target app nixbot@10.0.0.5 -o BatchMode=yes
            printf 'attempts:%s output:%s\n' "$attempts" "$PRIMARY_PROBE_LAST_OUTPUT"
            """
        )

        self.assertEqual(
            [
                "probe:1:ssh -o BatchMode=yes nixbot@10.0.0.5 true",
                "clear:app:primary",
                "sleep:1",
                "probe:2:ssh -o BatchMode=yes nixbot@10.0.0.5 true",
                "attempts:2 output:",
            ],
            result.stdout.splitlines(),
        )
        self.assertIn(
            "Primary connectivity probe for nixbot@10.0.0.5 transport unavailable; retrying (2/3) in 1s",
            result.stderr,
        )

    def test_parented_host_operation_retries_until_readiness_budget_is_exhausted_or_successful(self):
        result = self.run_script(
            f"""
            init_vars
            DRY_RUN=0
            NIXBOT_HOSTS_JSON='{{"app":{{"parent":"parent"}}}}'
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_STATE_LOCK_TIMEOUT=1
            ensure_tmp_dir
            sleep() {{ printf 'sleep:%s\n' "$1"; }}
            clear_control_master_socket() {{ printf 'clear:%s:%s\n' "$1" "$2"; }}
            attempts=0
            flaky_operation() {{
              attempts=$((attempts + 1))
              printf 'attempt:%s\n' "$attempts"
              [ "$attempts" -ge 3 ]
            }}
            run_host_operation_with_retry_budget app 'deploy transport preparation' 5 2 flaky_operation
            printf 'success-attempts:%s\n' "$attempts"

            attempts=0
            always_fails() {{
              attempts=$((attempts + 1))
              printf 'fail-attempt:%s\n' "$attempts"
              return 1
            }}
            set +e
            run_host_operation_with_retry_budget app 'deploy transport preparation' 3 2 always_fails
            printf 'failure-rc:%s attempts:%s\n' "$?" "$attempts"
            set -e
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual(
            [
                "clear:app:primary",
                "clear:app:bootstrap",
                "attempt:1",
                "sleep:2",
                "clear:app:primary",
                "clear:app:bootstrap",
                "attempt:2",
                "sleep:2",
                "clear:app:primary",
                "clear:app:bootstrap",
                "attempt:3",
                "success-attempts:3",
                "clear:app:primary",
                "clear:app:bootstrap",
                "fail-attempt:1",
                "sleep:2",
                "clear:app:primary",
                "clear:app:bootstrap",
                "fail-attempt:2",
                "failure-rc:1 attempts:2",
            ],
            lines,
        )
        self.assertIn("failed after parent barrier (parent); retrying in 2s", result.stderr)

    def test_sleep_for_retry_exits_early_when_cancel_was_requested(self):
        result = self.run_script(
            """
            init_vars
            sleep() { return 0; }
            NIXBOT_CANCEL_REQUESTED=1
            NIXBOT_CANCEL_EXIT_STATUS=130
            set +e
            sleep_for_retry_or_signal 5
            printf 'cancel-rc:%s\n' "$?"
            sleep() { return 143; }
            NIXBOT_CANCEL_REQUESTED=0
            sleep_for_retry_or_signal 5
            printf 'signal-rc:%s\n' "$?"
            set -e
            """
        )

        self.assertEqual(["cancel-rc:130", "signal-rc:143"], result.stdout.splitlines())

    def test_readiness_markers_persist_and_clear_primary_control_sockets(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            NIXBOT_STATE_LOCK_TIMEOUT=1
            ensure_tmp_dir
            clear_control_master_socket() {{ printf 'clear:%s:%s\n' "$1" "$2"; }}
            mark_bootstrap_ready app
            is_bootstrap_ready app && printf 'bootstrap-ready\n'
            mark_primary_ready app
            is_primary_ready app && printf 'primary-ready\n'
            clear_primary_ready app
            is_primary_ready app || printf 'primary-cleared\n'
            is_bootstrap_ready app && printf 'bootstrap-still-ready\n'
            """
        )

        self.assertEqual(
            [
                "bootstrap-ready",
                "primary-ready",
                "clear:app:primary",
                "clear:app:bootstrap",
                "primary-cleared",
                "bootstrap-still-ready",
            ],
            result.stdout.splitlines(),
        )

    def test_key_path_resolution_and_age_requirement_do_not_silently_accept_plain_keys(self):
        result = self.run_script(
            f"""
            init_vars
            mkdir -p {self.work_dir / "config"} {self.work_dir / "shared"}
            printf 'plain-key\n' >{self.work_dir / "plain-key"}
            printf 'config-key\n' >{self.work_dir / "config" / "deploy-key"}
            printf 'shared-key\n' >{self.work_dir / "shared" / "shared-key"}
            NIXBOT_CONFIG_DIR={self.work_dir / "config"}
            resolve_key_source_path ''
            resolve_key_source_path {self.work_dir / "plain-key"}
            resolve_key_source_path deploy-key
            resolve_key_source_path shared/shared-key
            resolve_key_source_path missing-key
            set +e
            resolve_runtime_key_file {self.work_dir / "plain-key"} 1 >{self.work_dir / "plain-key.out"}
            printf 'plain-age-rc:%s\n' "$?"
            set -e
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("", lines[0])
        self.assertEqual(str(self.work_dir / "plain-key"), lines[1])
        self.assertEqual(str(self.work_dir / "config" / "deploy-key"), lines[2])
        self.assertEqual(str(self.work_dir / "config" / "../shared/shared-key"), lines[3])
        self.assertEqual(str(self.work_dir / "config" / "../missing-key"), lines[4])
        self.assertEqual("plain-age-rc:1", lines[5])
        self.assertIn("Provided key path must point to an .age file", result.stderr)

    def test_bootstrap_check_uses_override_identity_without_leaking_deploy_identity(self):
        args_file = self.work_dir / "bootstrap-args.json"
        override_key = self.work_dir / "ci-check-key"
        result = self.run_script(
            f"""
            init_vars
            printf 'key\n' >{override_key}
            REMOTE_NIXBOT_DEPLOY_SCRIPT=/run/current-system/sw/bin/nixbot
            SHA=abc123
            NIXBOT_CONFIG_PATH=pkgs/tools/nixbot/config.json
            NIXBOT_CI_KEY_PATH_OVERRIDE={override_key}
            resolve_runtime_key_file() {{
              printf '%s\n' "$1"
            }}
            retry_transport_capture() {{
              local -n out_ref="$1"
              shift 3
              bash_args_to_json_array "$@" >{args_file}
              out_ref='ok'
              return 0
            }}
            check_bootstrap_via_forced_command app nixbot@10.0.0.5 -i deploy-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
            """
        )

        self.assertIn("Bootstrap check validated remote nixbot access for app", result.stdout)
        args = json.loads(args_file.read_text(encoding="utf-8"))
        self.assertEqual("ssh", args[0])
        self.assertEqual(["-i", str(override_key), "-o", "IdentitiesOnly=yes"], args[1:5])
        self.assertNotIn("deploy-key", args)
        self.assertIn("-o", args)
        self.assertIn("StrictHostKeyChecking=no", args)
        target_index = args.index("nixbot@10.0.0.5")
        self.assertEqual(
            ["/run/current-system/sw/bin/nixbot", "check-bootstrap", "--sha", "abc123", "--hosts", "app", "--config", "pkgs/tools/nixbot/config.json"],
            args[target_index + 1 :],
        )

    def test_deploy_wave_completion_buckets_failures_and_rolls_back_failed_hosts(self):
        result = self.run_script(
            f"""
            init_vars
            DRY_RUN=0
            ROLLBACK_ON_FAILURE=1
            NIXBOT_HOSTS_JSON='{{"ok":{{}},"skipped":{{}},"required":{{}},"optional":{{"deploy":"optional"}}}}'
            status_dir={self.work_dir / "status"}
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            mkdir -p "$status_dir" "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir"
            printf '0\n' >"$status_dir/ok.rc"
            printf 'skip\n' >"$status_dir/skipped.rc"
            printf '1\n' >"$status_dir/required.rc"
            printf '1\n' >"$status_dir/optional.rc"
            success=()
            skipped=()
            failed=()
            rollback_hosts_to_snapshots() {{
              local ok_hosts_name="$4"
              shift 5
              local -n ok_hosts_ref="$ok_hosts_name"
              local node=""
              for node in "$@"; do
                printf 'rollback:%s\n' "$node"
                ok_hosts_ref+=("$node")
              done
            }}
            set +e
            process_completed_deploy_wave_jobs \
              "$status_dir" "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" \
              success skipped failed \
              ok skipped optional required
            printf 'deploy-rc:%s\n' "$?"
            set -e
            bash_args_to_json_array "${{success[@]}}"
            bash_args_to_json_array "${{skipped[@]}}"
            bash_args_to_json_array "${{failed[@]}}"
            bash_args_to_json_array "${{OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS[@]}}"
            bash_args_to_json_array "${{DEPLOY_FAILED_ROLLBACK_OK_HOSTS[@]}}"
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("rollback:optional", lines[0])
        self.assertEqual("rollback:required", lines[1])
        self.assertEqual("deploy-rc:1", lines[2])
        self.assertEqual(["ok"], json.loads(lines[3]))
        self.assertEqual(["skipped"], json.loads(lines[4]))
        self.assertEqual(["required"], json.loads(lines[5]))
        self.assertEqual(["optional"], json.loads(lines[6]))
        self.assertEqual(["required"], json.loads(lines[7]))

    def test_deploy_wave_signal_short_circuits_before_rollbacks(self):
        result = self.run_script(
            f"""
            init_vars
            DRY_RUN=0
            ROLLBACK_ON_FAILURE=1
            NIXBOT_HOSTS_JSON='{{"required":{{}},"optional":{{"deploy":"optional"}},"signaled":{{}},"ok":{{}}}}'
            status_dir={self.work_dir / "status"}
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            mkdir -p "$status_dir" "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir"
            printf '1\n' >"$status_dir/optional.rc"
            printf '1\n' >"$status_dir/required.rc"
            printf '130\n' >"$status_dir/signaled.rc"
            printf '0\n' >"$status_dir/ok.rc"
            success=()
            skipped=()
            failed=()
            rollback_hosts_to_snapshots() {{
              shift 5
              printf 'unexpected-rollback:%s\n' "$*"
            }}
            set +e
            process_completed_deploy_wave_jobs \
              "$status_dir" "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" \
              success skipped failed \
              optional required signaled ok
            printf 'deploy-rc:%s\n' "$?"
            set -e
            bash_args_to_json_array "${{success[@]}}"
            bash_args_to_json_array "${{skipped[@]}}"
            bash_args_to_json_array "${{failed[@]}}"
            bash_args_to_json_array "${{OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS[@]}}"
            bash_args_to_json_array "${{DEPLOY_FAILED_ROLLBACK_OK_HOSTS[@]}}"
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("deploy-rc:130", lines[0])
        self.assertEqual([], json.loads(lines[1]))
        self.assertEqual([], json.loads(lines[2]))
        self.assertEqual([], json.loads(lines[3]))
        self.assertEqual([], json.loads(lines[4]))
        self.assertEqual([], json.loads(lines[5]))
        self.assertNotIn("unexpected-rollback", result.stdout)

    def test_deploy_wave_rollback_is_gated_by_dry_run_and_no_rollback(self):
        result = self.run_script(
            f"""
            init_vars
            NIXBOT_HOSTS_JSON='{{"required":{{}},"optional":{{"deploy":"optional"}}}}'
            status_dir={self.work_dir / "status"}
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            mkdir -p "$status_dir" "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir"
            printf '1\n' >"$status_dir/required.rc"
            printf '1\n' >"$status_dir/optional.rc"
            rollback_hosts_to_snapshots() {{
              printf 'unexpected-rollback:%s\n' "$*"
            }}
            run_case() {{
              local label="$1"
              DRY_RUN="$2"
              ROLLBACK_ON_FAILURE="$3"
              success=()
              skipped=()
              failed=()
              OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS=()
              DEPLOY_FAILED_ROLLBACK_OK_HOSTS=()
              set +e
              process_completed_deploy_wave_jobs \
                "$status_dir" "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" \
                success skipped failed \
                optional required
              printf '%s-rc:%s\n' "$label" "$?"
              set -e
              bash_args_to_json_array "${{success[@]}}"
              bash_args_to_json_array "${{skipped[@]}}"
              bash_args_to_json_array "${{failed[@]}}"
              bash_args_to_json_array "${{OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS[@]}}"
              bash_args_to_json_array "${{DEPLOY_FAILED_ROLLBACK_OK_HOSTS[@]}}"
            }}
            run_case dry 1 1
            run_case disabled 0 0
            """
        )

        lines = result.stdout.splitlines()
        self.assertNotIn("unexpected-rollback", result.stdout)
        self.assertEqual("dry-rc:1", lines[0])
        self.assertEqual([], json.loads(lines[1]))
        self.assertEqual([], json.loads(lines[2]))
        self.assertEqual(["required"], json.loads(lines[3]))
        self.assertEqual([], json.loads(lines[4]))
        self.assertEqual([], json.loads(lines[5]))
        self.assertEqual("disabled-rc:1", lines[6])
        self.assertEqual([], json.loads(lines[7]))
        self.assertEqual([], json.loads(lines[8]))
        self.assertEqual(["required"], json.loads(lines[9]))
        self.assertEqual([], json.loads(lines[10]))
        self.assertEqual([], json.loads(lines[11]))

    def test_rollback_waves_run_in_reverse_dependency_order_and_record_failures(self):
        result = self.run_script(
            f"""
            init_vars
            DRY_RUN=0
            ROLLBACK_ON_FAILURE=1
            NIXBOT_PARALLEL_JOBS=2
            NIXBOT_HOSTS_JSON='{{"parent":{{}},"db":{{}},"app":{{"parent":"parent","deps":["db"]}},"side":{{"parent":"parent"}},"worker":{{"after":["app"]}}}}'
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            order_file={self.work_dir / "rollback-order"}
            mkdir -p "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir"
            for node in parent db app side worker; do
              printf '/nix/store/test-nixos-system-%s\n' "$node" >"$snapshot_dir/$node.path"
            done
            rollback_host_to_snapshot() {{
              printf '%s\n' "$1" >>"$order_file"
              [ "$1" != side ]
            }}
            set +e
            rollback_successful_hosts "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" parent db app side worker
            printf 'rollback-rc:%s\n' "$?"
            set -e
            cat "$order_file"
            bash_args_to_json_array "${{ROLLBACK_OK_HOSTS[@]}}"
            bash_args_to_json_array "${{ROLLBACK_FAILED_HOSTS[@]}}"
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("rollback-rc:1", lines[0])
        order = lines[1:6]
        self.assertEqual("worker", order[0])
        self.assertEqual({"app", "side"}, set(order[1:3]))
        self.assertEqual({"parent", "db"}, set(order[3:5]))
        self.assertEqual(["worker", "app", "parent", "db"], json.loads(lines[6]))
        self.assertEqual(["side"], json.loads(lines[7]))

    def test_rollback_signal_stops_later_rollback_waves(self):
        result = self.run_script(
            f"""
            init_vars
            DRY_RUN=0
            ROLLBACK_ON_FAILURE=1
            NIXBOT_PARALLEL_JOBS=1
            NIXBOT_HOSTS_JSON='{{"parent":{{}},"app":{{"parent":"parent"}},"worker":{{"after":["app"]}}}}'
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            order_file={self.work_dir / "rollback-order"}
            mkdir -p "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir"
            for node in parent app worker; do
              printf '/nix/store/test-nixos-system-%s\n' "$node" >"$snapshot_dir/$node.path"
            done
            rollback_host_to_snapshot() {{
              printf '%s\n' "$1" >>"$order_file"
              [ "$1" != worker ] || return 130
            }}
            set +e
            rollback_successful_hosts "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" parent app worker
            printf 'rollback-rc:%s\n' "$?"
            set -e
            cat "$order_file"
            bash_args_to_json_array "${{ROLLBACK_OK_HOSTS[@]}}"
            bash_args_to_json_array "${{ROLLBACK_FAILED_HOSTS[@]}}"
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual(["rollback-rc:130", "worker"], lines[:2])
        self.assertEqual([], json.loads(lines[2]))
        self.assertEqual(["worker"], json.loads(lines[3]))

    def test_rollback_host_level_records_missing_snapshot_and_missing_status(self):
        result = self.run_script(
            f"""
            init_vars
            NIXBOT_PARALLEL_JOBS=1
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            mkdir -p "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir"
            printf '/nix/store/test-nixos-system-ok\n' >"$snapshot_dir/ok.path"
            printf '/nix/store/test-nixos-system-nostatus\n' >"$snapshot_dir/nostatus.path"
            ok_hosts=()
            failed_hosts=()
            run_rollback_job() {{
              if [ "$1" = ok ]; then
                write_status_file "$3" 0
              fi
              return 0
            }}
            set +e
            rollback_host_level_to_snapshots \
              "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" \
              ok_hosts failed_hosts \
              ok missing nostatus
            printf 'level-rc:%s\n' "$?"
            set -e
            bash_args_to_json_array "${{ok_hosts[@]}}"
            bash_args_to_json_array "${{failed_hosts[@]}}"
            printf 'missing-status:%s\n' "$(cat "$rollback_status_dir/missing.rc")"
            if [ -e "$rollback_status_dir/nostatus.rc" ]; then
              printf 'nostatus-status:%s\n' "$(cat "$rollback_status_dir/nostatus.rc")"
            else
              printf 'nostatus-status:missing\n'
            fi
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("level-rc:1", lines[0])
        self.assertEqual(["ok"], json.loads(lines[1]))
        self.assertEqual(["missing", "nostatus"], json.loads(lines[2]))
        self.assertEqual("missing-status:snapshot-missing", lines[3])
        self.assertEqual("nostatus-status:missing", lines[4])

    def test_health_check_failure_rolls_back_failed_and_remaining_successful_hosts(self):
        result = self.run_script(
            f"""
            init_vars
            ROLLBACK_ON_FAILURE=1
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            health_log_dir={self.work_dir / "health-log"}
            health_status_dir={self.work_dir / "health-status"}
            mkdir -p "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" "$health_log_dir" "$health_status_dir"
            successful=(app db)
            run_post_switch_health_check() {{
              [ "$1" = db ]
            }}
            rollback_failed_health_hosts() {{
              shift 3
              printf 'health-rollback:%s\n' "$*"
              HEALTH_FAILED_ROLLBACK_OK_HOSTS+=("$@")
            }}
            maybe_rollback_successful_hosts() {{
              shift 3
              printf 'remaining-rollback:%s\n' "$*"
              ROLLBACK_OK_HOSTS+=("$@")
            }}
            set +e
            run_post_switch_health_check_phase \
              "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" \
              "$health_log_dir" "$health_status_dir" \
              0 1 successful
            printf 'health-rc:%s\n' "$?"
            set -e
            bash_args_to_json_array "${{successful[@]}}"
            bash_args_to_json_array "${{HEALTH_FAILED_HOSTS[@]}}"
            bash_args_to_json_array "${{HEALTH_FAILED_ROLLBACK_OK_HOSTS[@]}}"
            bash_args_to_json_array "${{ROLLBACK_OK_HOSTS[@]}}"
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("health-rollback:app", lines[0])
        self.assertEqual("remaining-rollback:db", lines[1])
        self.assertEqual("health-rc:1", lines[2])
        self.assertEqual([], json.loads(lines[3]))
        self.assertEqual(["app"], json.loads(lines[4]))
        self.assertEqual(["app"], json.loads(lines[5]))
        self.assertEqual(["db"], json.loads(lines[6]))

    def test_health_check_success_output_is_concise(self):
        result = self.run_script(
            f"""
            init_vars
            ROLLBACK_ON_FAILURE=1
            snapshot_dir={self.work_dir / "snapshot"}
            rollback_log_dir={self.work_dir / "rollback-log"}
            rollback_status_dir={self.work_dir / "rollback-status"}
            health_log_dir={self.work_dir / "health-log"}
            health_status_dir={self.work_dir / "health-status"}
            mkdir -p "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" "$health_log_dir" "$health_status_dir"
            successful=(app)
            run_post_switch_health_check() {{ return 0; }}
            run_post_switch_health_check_phase \
              "$snapshot_dir" "$rollback_log_dir" "$rollback_status_dir" \
              "$health_log_dir" "$health_status_dir" \
              0 1 successful
            build_post_switch_health_check_cmd | grep -F '[health-check] ok'
            """
        )

        self.assertIn("[health-check] ok", result.stdout)
        self.assertIn("Scanning..", result.stderr)
        self.assertNotIn("Scanning deployed hosts for failed units", result.stderr)
        self.assertNotIn("All deployed hosts healthy", result.stderr)

    def test_deploy_failure_detection_ignores_optional_signal_and_pre_activation_cancel(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            ensure_tmp_dir
            NIXBOT_HOSTS_JSON='{{"required":{{}},"optional":{{"deploy":"optional"}},"signaled":{{}},"canceled":{{}}}}'
            status_dir={self.work_dir / "status"}
            mkdir -p "$status_dir"
            printf '1\n' >"$status_dir/optional.rc"
            printf '130\n' >"$status_dir/signaled.rc"
            printf '1\n' >"$status_dir/canceled.rc"
            printf '1\n' >"$status_dir/required.rc"
            : >"$(deploy_pre_activation_cancel_marker_file canceled)"
            find_completed_required_deploy_failure "$status_dir" optional signaled canceled required
            """
        )

        self.assertEqual("required", result.stdout.strip())

    def test_pre_activation_fail_fast_cancels_only_jobs_that_have_not_reached_activation(self):
        result = self.run_script(
            f"""
            init_vars
            RUNTIME_WORK_ROOT={self.work_dir / "runtime"}
            RUNTIME_WORK_FALLBACK_ROOT={self.work_dir / "runtime-fallback"}
            RUNTIME_WORK_DIR={self.work_dir / "runtime" / "run-test.id"}
            NIXBOT_DIAG_DIR={self.work_dir / "runtime" / "diag-test.id"}
            NIXBOT_CANCEL_TERM_GRACE_SECS=0
            mkdir -p "$RUNTIME_WORK_DIR" "$NIXBOT_DIAG_DIR"
            ensure_tmp_dir
            pre_alive=1
            active_alive=1
            kill() {{
              local signal="$1" pid="$2"
              if [ "$signal" = "-0" ]; then
                case "$pid" in
                  111) [ "$pre_alive" -eq 1 ] ;;
                  222) [ "$active_alive" -eq 1 ] ;;
                  *) return 1 ;;
                esac
                return "$?"
              fi
              return 0
            }}
            terminate_pid_tree() {{
              printf 'terminate:%s:%s\n' "$1" "$2"
              [ "$1" = 111 ] && pre_alive=0
              [ "$1" = 222 ] && active_alive=0
              return 0
            }}
            host_deploy_activation_unit_running() {{ return 1; }}
            register_deploy_job_pid pre 111
            register_deploy_job_pid active 222
            mark_deploy_activation_started active
            terminate_pre_activation_deploy_jobs failed
            [ -e "$(deploy_pre_activation_cancel_marker_file pre)" ] && printf 'pre-canceled\n'
            [ -e "$(deploy_pre_activation_cancel_marker_file active)" ] || printf 'active-not-canceled\n'
            [ "$active_alive" -eq 1 ] && printf 'active-still-running\n'
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("terminate:111:TERM", lines[0])
        self.assertEqual(["pre-canceled", "active-not-canceled", "active-still-running"], lines[1:])
        self.assertIn("leaving active activation to finish", result.stderr)
        self.assertIn("canceling pre-activation deploy for pre", result.stderr)

    def test_interrupt_request_exits_before_deploy_and_escalates_active_deploy_cancel(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_FORCE_CANCEL_SIGNAL_COUNT=3
            NIXBOT_FORCE_CANCEL_WINDOW_SECS=60
            terminate_background_jobs() { printf 'terminate:%s\n' "${1:-normal}"; }
            cancel_active_deploy_activation_units() { printf 'remote-cancel\n'; }

            active_deploy_jobs_running() { return 1; }
            deploy_jobs_started() { return 1; }
            set +e
            (request_cancel 130 INT)
            printf 'before-deploy-rc:%s\n' "$?"
            set -e

            NIXBOT_CANCEL_REQUESTED=0
            active_deploy_jobs_running() { return 0; }
            deploy_jobs_started() { return 0; }
            request_cancel 130 INT
            printf 'after-first:%s force:%s\n' "$NIXBOT_CANCEL_REQUESTED" "$(force_cancel_requested && printf yes || printf no)"
            request_cancel 130 INT
            printf 'after-second:%s force:%s\n' "$NIXBOT_CANCEL_REQUESTED" "$(force_cancel_requested && printf yes || printf no)"
            set +e
            (request_cancel 130 INT)
            printf 'force-rc:%s\n' "$?"
            set -e
            """
        )

        self.assertEqual(
            [
                "terminate:normal",
                "before-deploy-rc:130",
                "after-first:1 force:no",
                "after-second:2 force:no",
                "remote-cancel",
                "terminate:force",
                "force-rc:130",
            ],
            result.stdout.splitlines(),
        )
        self.assertIn("no deploy job has started, canceling local jobs", result.stderr)
        self.assertIn("waiting for active deploy jobs to finish", result.stderr)
        self.assertIn("best-effort canceling activation", result.stderr)

    def test_run_summary_failure_detection_includes_deploy_health_rollback_and_tf_failures(self):
        result = self.run_script(
            """
            init_vars
            clear_run_summary_state
            run_summary_has_failures || printf 'clean\n'
            RUN_SUMMARY_DEPLOY_FAILED_HOSTS=(app)
            run_summary_has_failures && printf 'deploy-failed\n'
            clear_run_summary_state
            RUN_SUMMARY_HEALTH_FAILED_HOSTS=(app)
            run_summary_has_failures && printf 'health-failed\n'
            clear_run_summary_state
            RUN_SUMMARY_ROLLBACK_FAILED_HOSTS=(app)
            run_summary_has_failures && printf 'rollback-failed\n'
            clear_run_summary_state
            RUN_SUMMARY_TF_STATUSES=(ok skip fail)
            run_summary_has_failures && printf 'tf-failed\n'
            """
        )

        self.assertEqual(
            ["clean", "deploy-failed", "health-failed", "rollback-failed", "tf-failed"],
            result.stdout.splitlines(),
        )

    def test_host_log_filter_skips_prefix_when_prefix_context_is_active(self):
        result = self.run_script(
            """
            init_vars
            LOG_FORMAT=plain
            FORCE_PREFIX_HOST_LOGS=1
            emit_inner() {
              printf 'inner\\n' | host_log_filter web
            }
            printf 'outer\\n' | host_log_filter web
            run_with_host_log_prefix_context deploy emit_inner
            """
        )

        self.assertEqual(["| web | outer", "inner"], result.stdout.splitlines())

    def test_run_streamed_host_command_prefixes_nested_host_logs_once(self):
        log_file = self.work_dir / "streamed.log"
        result = self.run_script(
            f"""
            init_vars
            LOG_FORMAT=plain
            FORCE_PREFIX_HOST_LOGS=1
            emit_nested_host_output() {{
              printf 'nested\\n' | host_log_filter web
            }}
            run_streamed_host_command deploy web {log_file} emit_nested_host_output
            printf 'log:%s\\n' "$(cat {log_file})"
            """
        )

        self.assertEqual(
            ["| web | nested", "log:| web | nested"],
            result.stdout.splitlines(),
        )

    def test_run_streamed_host_command_keeps_persisted_log_plain_when_terminal_is_colored(self):
        log_file = self.work_dir / "streamed-color.log"
        result = self.run_script(
            f"""
            init_vars
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            FORCE_PREFIX_HOST_LOGS=1
            emit_nested_host_output() {{
              printf 'nested\\n' | host_log_filter web
            }}
            run_streamed_host_command deploy web {log_file} emit_nested_host_output >/dev/null
            if LC_ALL=C grep -q $'\\033' {log_file}; then
              printf 'ansi-log\n'
            else
              printf 'log:%s\n' "$(cat {log_file})"
            fi
            """
        )

        self.assertEqual(["log:| web | nested"], result.stdout.splitlines())

    def test_run_streamed_host_command_strips_colored_inner_headers_from_log(self):
        log_file = self.work_dir / "streamed-rollback.log"
        result = self.run_script(
            f"""
            init_vars
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            FORCE_PREFIX_HOST_LOGS=1
            emit_rollback_output() {{
              log_host_stage rollback web
              printf 'body\\n'
            }}
            run_streamed_host_command rollback web {log_file} emit_rollback_output
            if LC_ALL=C grep -q $'\\033' {log_file}; then
              printf 'ansi-log\n'
            else
              printf 'plain-log\n'
            fi
            printf 'log:%s\n' "$(grep -m1 'rollback' {log_file})"
            """
        )

        self.assertIn("| \x1b[90mweb\x1b[0m |", result.stdout)
        self.assertEqual(["plain-log", "log:| web | -------- web | rollback --------"], result.stdout.splitlines()[-2:])

    def test_run_streamed_host_command_keeps_unprefixed_persisted_log_plain(self):
        log_file = self.work_dir / "streamed-unprefixed-color.log"
        result = self.run_script(
            f"""
            init_vars
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            FORCE_PREFIX_HOST_LOGS=0
            emit_colored_output() {{
              log_host_stage rollback web
              printf 'body\\n'
            }}
            run_streamed_host_command rollback web {log_file} emit_colored_output >/dev/null
            if LC_ALL=C grep -q $'\\033' {log_file}; then
              printf 'ansi-log\n'
            else
              printf 'plain-log\n'
            fi
            printf 'log:%s\n' "$(grep -m1 'rollback' {log_file})"
            """
        )

        self.assertEqual(["plain-log", "log:-------- web | rollback --------"], result.stdout.splitlines())

    def test_append_host_log_filter_keeps_persisted_log_plain_when_terminal_is_colored(self):
        log_file = self.work_dir / "append-color.log"
        result = self.run_script(
            f"""
            init_vars
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            FORCE_PREFIX_HOST_LOGS=1
            printf 'built-path\\n' | append_host_log_filter web {log_file}
            if LC_ALL=C grep -q $'\\033' {log_file}; then
              printf 'ansi-log\n'
            else
              printf 'log:%s\n' "$(cat {log_file})"
            fi
            """
        )

        self.assertEqual(["log:| web | built-path"], result.stdout.splitlines())

    def test_print_run_summary_host_color_does_not_inherit_rollback_phase(self):
        result = self.run_script(
            """
            init_vars
            ACTION=deploy
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            RUN_SUMMARY_SELECTED_HOSTS=(web)
            RUN_SUMMARY_DEPLOY_OK_HOSTS=(web)
            _NIXBOT_HOST_LOG_PHASE=rollback
            print_run_summary 0
            """
        )

        self.assertNotIn("\x1b[90mweb\x1b[0m", result.stderr)
        self.assertIn("web", result.stderr)

    def test_print_run_summary_colors_host_lines_by_outcome(self):
        result = self.run_script(
            """
            init_vars
            ACTION=deploy
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            RUN_SUMMARY_SELECTED_HOSTS=(okhost rolled skipped optional failed)
            RUN_SUMMARY_DEPLOY_OK_HOSTS=(okhost)
            RUN_SUMMARY_ROLLBACK_OK_HOSTS=(rolled)
            RUN_SUMMARY_DEPLOY_SKIPPED_HOSTS=(skipped)
            RUN_SUMMARY_OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS=(optional)
            RUN_SUMMARY_DEPLOY_FAILED_HOSTS=(failed)
            print_run_summary 1
            """
        )

        lines = result.stderr.splitlines()
        self.assertIn("  - okhost: \x1b[32mok\x1b[0m", lines)
        self.assertIn("\x1b[90m  - rolled: rolled back\x1b[0m", lines)
        self.assertIn("\x1b[90m  - skipped: ok (skip)\x1b[0m", lines)
        self.assertIn("\x1b[33m  - optional: optional (rollback failed)\x1b[0m", lines)
        self.assertIn("\x1b[31m  - failed: FAIL (deploy)\x1b[0m", lines)
        self.assertNotIn("\x1b[90mokhost\x1b[0m", result.stderr)
        self.assertNotIn("\x1b[36mokhost\x1b[0m", result.stderr)


    def test_should_use_color_respects_no_color_and_force_color(self):
        result = self.run_script(
            """
            init_vars
            LOG_FORMAT=plain
            unset NO_COLOR
            should_use_color && printf 'default-yes\\n' || printf 'default-no\\n'
            NO_COLOR=1 should_use_color && printf 'nocolor-yes\\n' || printf 'nocolor-no\\n'
            NIXBOT_FORCE_COLOR=1 should_use_color && printf 'force-yes\\n' || printf 'force-no\\n'
            """
        )
        lines = result.stdout.splitlines()
        self.assertIn(lines[0], ("default-yes", "default-no"))
        self.assertEqual(lines[1], "nocolor-no")
        self.assertEqual(lines[2], "force-yes")

    def test_should_use_color_disabled_in_github_actions_mode(self):
        result = self.run_script(
            """
            init_vars
            LOG_FORMAT=gh
            should_use_color && printf 'gh-yes\\n' || printf 'gh-no\\n'
            LOG_FORMAT=plain
            GITHUB_ACTIONS=true should_use_color && printf 'auto-gh-yes\\n' || printf 'auto-gh-no\\n'
            """
        )
        self.assertEqual(result.stdout.splitlines(), ["gh-no", "auto-gh-no"])

    def test_host_color_index_is_stable_and_within_palette(self):
        result = self.run_script(
            """
            init_vars
            printf 'idx-alpha:%s\\n' "$(host_color_index alpha)"
            printf 'idx-alpha2:%s\\n' "$(host_color_index alpha)"
            printf 'idx-bravo:%s\\n' "$(host_color_index bravo)"
            printf 'palette-size:%s\\n' "${#_NIXBOT_HOST_PALETTE[@]}"
            """
        )
        lines = result.stdout.splitlines()
        alpha_idx = lines[0].split(":")[1]
        alpha_idx2 = lines[1].split(":")[1]
        bravo_idx = lines[2].split(":")[1]
        palette_size = int(lines[3].split(":")[1])
        self.assertEqual(alpha_idx, alpha_idx2)
        self.assertNotEqual(alpha_idx, bravo_idx)
        self.assertGreaterEqual(int(alpha_idx), 0)
        self.assertLess(int(alpha_idx), palette_size)

    def test_host_color_code_uses_gray_for_rollback_phase(self):
        result = self.run_script(
            """
            init_vars
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            printf 'deploy:%s\\n' "$(host_color_code web deploy)"
            printf 'rollback:%s\\n' "$(host_color_code web rollback)"
            printf 'gray:%s\\n' "${_NIXBOT_C_GRAY}"
            """
        )
        lines = result.stdout.splitlines()
        deploy_code = lines[0].split(":", 1)[1]
        rollback_code = lines[1].split(":", 1)[1]
        gray_code = lines[2].split(":", 1)[1]
        self.assertNotEqual(deploy_code, rollback_code)
        self.assertEqual(rollback_code, gray_code)

    def test_colorize_wraps_text_when_color_enabled(self):
        result = self.run_script(
            """
            init_vars
            LOG_FORMAT=plain
            NIXBOT_FORCE_COLOR=1
            printf '%s\\n' "$(colorize "${_NIXBOT_C_GREEN}" hello)"
            printf '%s\\n' "$(NIXBOT_FORCE_COLOR= colorize "${_NIXBOT_C_GREEN}" hello)"
            """
        )
        lines = result.stdout.splitlines()
        self.assertIn("hello", lines[0])
        self.assertNotEqual(lines[0], "hello")
        self.assertEqual(lines[1], "hello")

    def test_status_color_code_maps_statuses(self):
        result = self.run_script(
            """
            init_vars
            printf 'ok:%s\\n' "$(status_color_code ok)"
            printf 'built:%s\\n' "$(status_color_code built)"
            printf 'fail:%s\\n' "$(status_color_code 'FAIL (deploy)')"
            printf 'skip:%s\\n' "$(status_color_code skip)"
            printf 'rollback:%s\\n' "$(status_color_code 'rolled back')"
            """
        )
        lines = result.stdout.splitlines()
        green = lines[0].split(":", 1)[1]
        red = lines[2].split(":", 1)[1]
        gray = lines[3].split(":", 1)[1]
        self.assertEqual(lines[1].split(":", 1)[1], green)
        self.assertEqual(lines[4].split(":", 1)[1], gray)
        self.assertNotEqual(green, red)
        self.assertNotEqual(green, gray)
        self.assertNotEqual(red, gray)


if __name__ == "__main__":
    unittest.main()
