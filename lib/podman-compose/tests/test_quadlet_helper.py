import subprocess
import textwrap
import unittest
from pathlib import Path


class QuadletHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.helper = cls.repo_root / "lib/podman-compose/helper.sh"
        cls.quadlet_helper = cls.repo_root / "lib/podman-compose/quadlet-helper.sh"

    def run_script(self, body: str, *, check=True):
        script = textwrap.dedent(
            f"""
            set -Eeuo pipefail
            source {self.helper}
            source {self.quadlet_helper}
            podman_compose_service_name=test-native
            backend=quadlet
            runtime_dir=/run/user/1234
            quadlet_container_unit=test-native-container.service
            quadlet_container_name=test-native-container
            quadlet_source_path=/etc/containers/systemd/users/1234/test-native-container.container
            quadlet_labels_json='{{"io.abird.podman-compose.backend":"quadlet"}}'
            {body}
            """
        )
        return subprocess.run(
            ["bash", "-c", script],
            cwd=self.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_start_transaction_commits_only_after_unit_and_container_postcondition(self):
        result = self.run_script(
            """
            begin_rootless_mutation() { printf 'begin:%s\n' "$1"; }
            backend_transition_admit() { :; }
            run_bootstrap_phase() { printf 'bootstrap\n'; }
            quadlet_stop_private_unit() { printf 'systemctl:--user stop test-native-container.service\n'; }
            quadlet_unit_state() { printf 'inactive\n'; }
            systemctl() { printf 'systemctl:%s\n' "$*"; }
            quadlet_cleanup_postcondition() { printf 'cleanup-postcondition\n'; }
            quadlet_start_postcondition() { printf 'postcondition\n'; }
            commit_rootless_mutation() { printf 'commit\n'; }
            quadlet_start_transaction
            """
        )
        self.assertEqual(
            [
                "begin:quadlet start transaction",
                "systemctl:--user stop test-native-container.service",
                "cleanup-postcondition",
                "bootstrap",
                "systemctl:--user start test-native-container.service",
                "postcondition",
                "commit",
            ],
            result.stdout.splitlines(),
        )

    def test_successful_quadlet_convergence_records_all_recreate_stamps(self):
        result = self.run_script(
            """
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            helper_invoked_as_script() { return 1; }
            lock_lifecycle_exclusive() { :; }
            unlock_lifecycle_exclusive() { :; }
            rm() { :; }
            clear_removal_policy_marker() { :; }
            record_staging_runtime_state() { :; }
            stage_runtime_files() { :; }
            mark_start_in_progress() { :; }
            clear_start_in_progress() { :; }
            quadlet_start_transaction() { :; }
            record_runtime_state() { printf 'restart-only\n'; }
            record_applied_recreate_state() { printf 'recreate-applied\n'; }
            failed_start_cleanup_complete_path=/tmp/unused
            quadlet_start_locked false
            """
        )
        self.assertEqual(["recreate-applied"], result.stdout.splitlines())

    def test_compose_state_is_refreshed_for_quadlet_without_changing_ownership(self):
        result = self.run_script(
            """
            generated_dir="$(mktemp -d)"
            state_path="$generated_dir/state.json"
            runtime_state_version=3
            runtime_state_kind=podman-compose-runtime-state
            adoption_stamp=stable-owner
            reconcile_policy=auto
            restart_stamp=quadlet-restart
            recreate_tag=quadlet-tag
            recreate_stamp=quadlet-recreate
            recreate_class_stamp=quadlet-class
            backend=quadlet
            podman_compose_metadata="$generated_dir/metadata.json"
            printf '%s\n' '{"backendData":{"quadlet":{"containerUnit":"test-native-container.service"}}}' >"$podman_compose_metadata"
            printf '%s\n' '{"version":3,"kind":"podman-compose-runtime-state","adoptionStamp":"stable-owner","restartStamp":"compose-restart","recreateStamp":"compose-recreate"}' >"$state_path"

            record_applied_recreate_state
            jq -c '{adoptionStamp,appliedBackend,restartStamp,recreateTag,recreateStamp,recreateClassStamp}' "$state_path"
            """
        )
        self.assertEqual(
            [
                '{"adoptionStamp":"stable-owner","appliedBackend":"quadlet","restartStamp":"quadlet-restart",'
                '"recreateTag":"quadlet-tag","recreateStamp":"quadlet-recreate",'
                '"recreateClassStamp":"quadlet-class"}'
            ],
            [result.stdout.strip()],
        )

    def test_dirty_compose_to_quadlet_transition_fails_before_mutation(self):
        result = self.run_script(
            """
            generated_dir="$(mktemp -d)"
            state_path="$generated_dir/state.json"
            runtime_state_version=3
            runtime_state_kind=podman-compose-runtime-state
            adoption_stamp=stable-owner
            printf '%s\n' '{"version":3,"kind":"podman-compose-runtime-state","adoptionStamp":"stable-owner"}' >"$state_path"
            compose_project_container_ids() { printf 'old-compose-container\n'; }
            begin_rootless_mutation() { printf 'begin\n'; }
            rollback_rootless_mutation_clean() { printf 'rollback-clean\n'; }
            leave_rootless_runtime_dirty() { printf 'DIRTY:%s\n' "$1"; }
            systemctl() { printf 'MUTATED:%s\n' "$*"; }
            set +e
            quadlet_start_transaction
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(
            [
                "begin",
                "rollback-clean",
                "status:1",
            ],
            result.stdout.splitlines(),
        )
        self.assertNotIn("MUTATED", result.stdout)
        self.assertNotIn("DIRTY", result.stdout)
        self.assertIn("prior Compose containers remain", result.stderr)

    def test_unowned_quadlet_unit_releases_clean_without_mutation(self):
        result = self.run_script(
            """
            begin_rootless_mutation() { printf 'begin\n'; }
            backend_transition_admit() { :; }
            quadlet_unit_state() { printf 'unowned unit\n' >&2; return 1; }
            rollback_rootless_mutation_clean() { printf 'rollback-clean\n'; }
            leave_rootless_runtime_dirty() { printf 'DIRTY:%s\n' "$1"; }
            systemctl() { printf 'MUTATED:%s\n' "$*"; }
            set +e
            quadlet_start_transaction
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(
            ["begin", "rollback-clean", "status:1"], result.stdout.splitlines()
        )
        self.assertNotIn("DIRTY", result.stdout)
        self.assertNotIn("MUTATED", result.stdout)

    def test_staging_preserves_prior_backend_for_transition_admission(self):
        result = self.run_script(
            """
            generated_dir="$(mktemp -d)"
            state_path="$generated_dir/state.json"
            runtime_state_version=3
            runtime_state_kind=podman-compose-runtime-state
            adoption_stamp=stable-owner
            reconcile_policy=auto
            restart_stamp=quadlet-restart
            printf '%s\n' '{
              "version":3,
              "kind":"podman-compose-runtime-state",
              "adoptionStamp":"stable-owner",
              "appliedBackend":"compose",
              "appliedBackendData":{}
            }' >"$state_path"
            load_metadata() { :; }
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            lock_lifecycle_exclusive() { :; }
            unlock_lifecycle_exclusive() { :; }
            stage_runtime_files() { :; }
            compose_project_container_ids() { printf 'old-compose-container\n'; }

            cmd_stage
            jq -r '[.appliedBackend, .startupPhase] | @tsv' "$state_path"
            set +e
            backend_transition_admit
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(
            ["compose\tstaging", "status:1"], result.stdout.splitlines()
        )
        self.assertIn("prior Compose containers remain", result.stderr)

    def test_active_quadlet_to_compose_transition_fails_closed(self):
        result = self.run_script(
            """
            backend=compose
            generated_dir="$(mktemp -d)"
            state_path="$generated_dir/state.json"
            runtime_state_version=3
            runtime_state_kind=podman-compose-runtime-state
            adoption_stamp=stable-owner
            printf '%s\n' '{
              "version":3,
              "kind":"podman-compose-runtime-state",
              "adoptionStamp":"stable-owner",
              "appliedBackend":"quadlet",
              "appliedBackendData":{"quadlet":{
                "containerUnit":"test-native-container.service",
                "sourcePath":"/etc/containers/systemd/users/1234/test-native-container.container",
                "labels":{"io.abird.podman-compose.backend":"quadlet"}
              }}
            }' >"$state_path"
            systemctl() {
              printf 'loaded\nactive\n/etc/containers/systemd/users/1234/test-native-container.container\n/run/user/1234/systemd/generator/test-native-container.service\n'
            }
            set +e
            backend_transition_admit
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(["status:1"], result.stdout.splitlines())
        self.assertIn("prior Quadlet unit is not clean", result.stderr)

    def test_failed_start_rolls_back_only_after_clean_absence_is_proven(self):
        result = self.run_script(
            """
            begin_rootless_mutation() { printf 'begin\n'; }
            backend_transition_admit() { :; }
            run_bootstrap_phase() { :; }
            quadlet_stop_private_unit() { printf 'systemctl:--user stop test-native-container.service\n'; }
            quadlet_unit_state() { printf 'inactive\n'; }
            systemctl() {
              printf 'systemctl:%s\n' "$*"
              case "$*" in *' start '*) return 1 ;; esac
            }
            quadlet_cleanup_postcondition() { printf 'absent\n'; }
            rollback_rootless_mutation_clean() { printf 'rollback-clean\n'; }
            set +e
            quadlet_start_transaction
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(
            [
                "begin",
                "systemctl:--user stop test-native-container.service",
                "absent",
                "systemctl:--user start test-native-container.service",
                "systemctl:--user stop test-native-container.service",
                "absent",
                "rollback-clean",
                "status:1",
            ],
            result.stdout.splitlines(),
        )

    def test_indeterminate_failed_start_marks_runtime_dirty(self):
        result = self.run_script(
            """
            begin_rootless_mutation() { :; }
            backend_transition_admit() { :; }
            quadlet_unit_state() { printf 'inactive\n'; }
            run_bootstrap_phase() { return 1; }
            quadlet_stop_private_unit() { printf 'systemctl:--user stop test-native-container.service\n'; }
            systemctl() { printf 'systemctl:%s\n' "$*"; }
            cleanup_count=0
            quadlet_cleanup_postcondition() {
              cleanup_count=$((cleanup_count + 1))
              [ "$cleanup_count" -eq 1 ]
            }
            leave_rootless_runtime_dirty() { printf 'dirty:%s\n' "$1"; }
            set +e
            quadlet_start_transaction
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(
            [
                "systemctl:--user stop test-native-container.service",
                "systemctl:--user stop test-native-container.service",
                "dirty:failed Quadlet start cleanup was indeterminate for test-native",
                "status:1",
            ],
            result.stdout.splitlines(),
        )

    def test_container_absence_fails_closed_when_podman_query_errors(self):
        result = self.run_script(
            """
            podman_no_notify() { return 2; }
            set +e
            quadlet_container_absent
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(["status:1"], result.stdout.splitlines())
        self.assertIn("cannot determine whether Quadlet container", result.stderr)

    def test_unit_state_accepts_not_found_but_rejects_manager_errors(self):
        result = self.run_script(
            """
            systemctl() { printf 'not-found\ninactive\n\n\n'; }
            quadlet_unit_state

            systemctl() { return 1; }
            set +e
            quadlet_unit_state
            status=$?
            set -e
            printf 'query-error:%s\n' "$status"
            """
        )
        self.assertEqual(["absent", "query-error:1"], result.stdout.splitlines())
        self.assertIn("cannot query state", result.stderr)

    def test_unit_state_rejects_a_shadowing_static_unit_without_mutating_it(self):
        result = self.run_script(
            """
            systemctl() {
              case "$*" in
                *' show '*) printf 'loaded\nactive\n\n/home/tester/.config/systemd/user/test-native-container.service\n' ;;
                *) printf 'MUTATED:%s\n' "$*" ;;
              esac
            }
            set +e
            quadlet_stop_private_unit
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(["status:1"], result.stdout.splitlines())
        self.assertNotIn("MUTATED", result.stdout)
        self.assertIn("refusing unowned Quadlet unit", result.stderr)

    def test_stop_transaction_releases_clean_for_shadowing_unit(self):
        result = self.run_script(
            """
            begin_rootless_mutation() { printf 'begin\n'; }
            quadlet_unit_state() { printf 'shadowed\n' >&2; return 1; }
            rollback_rootless_mutation_clean() { printf 'rollback-clean\n'; }
            leave_rootless_runtime_dirty() { printf 'DIRTY:%s\n' "$1"; }
            systemctl() { printf 'MUTATED:%s\n' "$*"; }
            set +e
            quadlet_stop_transaction
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(
            ["begin", "rollback-clean", "status:1"], result.stdout.splitlines()
        )
        self.assertNotIn("DIRTY", result.stdout)
        self.assertNotIn("MUTATED", result.stdout)

    def test_quadlet_stop_accepts_clean_generation_drain_policy(self):
        result = self.run_script(
            """
            begin_rootless_mutation() { printf 'begin:%s\n' "$*"; }
            quadlet_unit_state() { printf 'absent\n'; }
            quadlet_stop_private_unit() { :; }
            quadlet_cleanup_postcondition() { :; }
            commit_rootless_mutation() { printf 'commit\n'; }
            quadlet_stop_transaction commit drain
            """
        )
        self.assertEqual(
            ["begin:quadlet stop transaction drain", "commit"],
            result.stdout.splitlines(),
        )

    def test_container_readiness_honors_image_health(self):
        result = self.run_script(
            """
            health=none
            quadlet_container_json() {
              jq -nc --arg health "$health" '{
                State: ({Status:"running"} + (if $health == "none" then {} else {Health:{Status:$health}} end)),
                Config:{Labels:{"io.abird.podman-compose.backend":"quadlet"}}
              } | [.]'
            }
            quadlet_container_readiness_state
            health=healthy
            quadlet_container_readiness_state
            health=starting
            quadlet_container_readiness_state
            health=unhealthy
            quadlet_container_readiness_state
            """
        )
        self.assertEqual(
            ["ready", "ready", "starting", "unhealthy"],
            result.stdout.splitlines(),
        )

    def test_verify_retries_running_unhealthy_until_healthy(self):
        result = self.run_script(
            """
            quadlet_load_metadata() { verify_transition_wait_seconds=10; }
            wait_for_verify_transition() { :; }
            lock_lifecycle_shared() { :; }
            unlock_lifecycle_shared() { :; }
            verify_transition_active() { return 1; }
            verify_staged_runtime_files() { :; }
            verify_runtime_state_current() { :; }
            quadlet_unit_active() { :; }
            run_verify_command() { printf 'verified\n'; }
            sleep() { :; }
            now_epoch() { printf '0\n'; }
            readiness_count_file="$(mktemp)"
            printf '0\n' >"$readiness_count_file"
            quadlet_container_readiness_state() {
              readiness_count="$(cat "$readiness_count_file")"
              readiness_count=$((readiness_count + 1))
              printf '%s\n' "$readiness_count" >"$readiness_count_file"
              if [ "$readiness_count" -eq 1 ]; then
                printf 'unhealthy\n'
              else
                printf 'ready\n'
              fi
            }
            quadlet_cmd_verify
            """
        )

        self.assertEqual(["verified"], result.stdout.splitlines())

    def test_prepare_image_pull_defers_when_service_lifecycle_is_busy(self):
        result = self.run_script(
            """
            quadlet_load_metadata() {
              declared_images=(docker.io/library/nginx:latest)
              image_pull_preflight_policy=prepare
              prepare_lock_timeout_seconds=1
            }
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            image_pull_state_current() { return 1; }
            declared_images_present() { return 1; }
            lock_lifecycle_exclusive_timeout() {
              printf 'lifecycle:%s\n' "$1"
              return 1
            }
            begin_rootless_mutation_timeout() { printf 'MUTATED\n'; }
            record_image_pull_status() { printf 'status:%s\n' "$1"; }
            quadlet_pull_images() { printf 'MUTATED\n'; }

            quadlet_cmd_image_pull
            """
        )

        self.assertEqual(
            ["lifecycle:1", "status:deferred"],
            result.stdout.splitlines(),
        )
        self.assertNotIn("MUTATED", result.stdout)

    def test_prepare_image_pull_defers_when_shared_rootless_runtime_is_busy(self):
        result = self.run_script(
            """
            quadlet_load_metadata() {
              declared_images=(docker.io/library/nginx:latest)
              image_pull_preflight_policy=prepare
              prepare_lock_timeout_seconds=2
            }
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            image_pull_state_current() { return 1; }
            declared_images_present() { return 1; }
            lock_lifecycle_exclusive_timeout() {
              printf 'lifecycle:%s\n' "$1"
            }
            begin_rootless_mutation_timeout() {
              printf 'rootless:%s\n' "$*"
              return 1
            }
            unlock_lifecycle_exclusive() { printf 'unlock\n'; }
            record_image_pull_status() { printf 'status:%s\n' "$1"; }
            quadlet_pull_images() { printf 'MUTATED\n'; }

            quadlet_cmd_image_pull
            """
        )

        self.assertEqual(
            [
                "lifecycle:2",
                "rootless:2 quadlet image pull prepare",
                "unlock",
                "status:deferred",
            ],
            result.stdout.splitlines(),
        )
        self.assertNotIn("MUTATED", result.stdout)

    def test_runtime_image_pull_contention_fails_closed(self):
        result = self.run_script(
            """
            quadlet_load_metadata() {
              declared_images=(docker.io/library/nginx:latest)
              image_pull_preflight_policy=current
            }
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            image_pull_state_current() { return 1; }
            declared_images_present() { return 1; }
            begin_image_pull_mutation() {
              printf 'begin:%s\n' "$1"
              return 1
            }
            record_image_pull_status() { printf 'status:%s\n' "$1"; }
            quadlet_pull_images() { printf 'MUTATED\n'; }

            set +e
            quadlet_cmd_image_pull
            status=$?
            set -e
            printf 'result:%s\n' "$status"
            """
        )

        self.assertEqual(
            ["begin:quadlet image pull", "result:1"],
            result.stdout.splitlines(),
        )
        self.assertNotIn("status:deferred", result.stdout)
        self.assertNotIn("MUTATED", result.stdout)

    def test_quadlet_image_pull_uses_shared_admission_and_commits(self):
        result = self.run_script(
            """
            quadlet_load_metadata() {
              declared_images=(docker.io/library/nginx:latest)
              image_pull_preflight_policy=prepare
            }
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            image_pull_state_current() { return 1; }
            declared_images_present() { return 1; }
            begin_image_pull_mutation() { printf 'begin:%s\n' "$1"; }
            quadlet_pull_images() { printf 'pull\n'; }
            commit_rootless_mutation() { printf 'commit\n'; }
            record_image_pull_state() { printf 'record-state\n'; }
            record_image_pull_status() { printf 'status:%s\n' "$1"; }
            unlock_lifecycle_exclusive() { printf 'unlock\n'; }

            quadlet_cmd_image_pull
            """
        )

        self.assertEqual(
            [
                "begin:quadlet image pull",
                "pull",
                "commit",
                "record-state",
                "status:pulled",
                "unlock",
            ],
            result.stdout.splitlines(),
        )

    def test_present_quadlet_image_never_blocks_on_lifecycle_stamp_update(self):
        result = self.run_script(
            """
            quadlet_load_metadata() {
              declared_images=(docker.io/library/nginx:latest)
              image_pull_preflight_policy=prepare
            }
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            image_pull_state_current() { return 1; }
            declared_images_present() { return 0; }
            lock_lifecycle_exclusive_timeout() {
              printf 'bounded-lock:%s\n' "$1"
              return 1
            }
            lock_lifecycle_exclusive() { printf 'BLOCKED\n'; }
            begin_image_pull_mutation() { printf 'MUTATED\n'; }
            record_image_pull_state() { printf 'record-state\n'; }
            record_image_pull_status() { printf 'status:%s\n' "$1"; }

            quadlet_cmd_image_pull
            """
        )

        self.assertEqual(
            ["bounded-lock:1", "status:skipped"],
            result.stdout.splitlines(),
        )
        self.assertNotIn("BLOCKED", result.stdout)
        self.assertNotIn("MUTATED", result.stdout)
        self.assertNotIn("record-state", result.stdout)

    def test_preflight_never_removes_a_same_named_unlabeled_container(self):
        result = self.run_script(
            """
            podman_no_notify() {
              printf 'podman:%s\n' "$*"
              case "$*" in 'container exists '*) return 0 ;; esac
            }
            quadlet_container_labeled() { return 1; }
            systemctl() { printf 'systemctl:%s\n' "$*"; }
            set +e
            quadlet_runtime_preflight_cleanup
            status=$?
            set -e
            printf 'status:%s\n' "$status"
            """
        )
        self.assertEqual(
            ["status:1"],
            result.stdout.splitlines(),
        )
        self.assertNotIn("rm --force", result.stdout)
        self.assertNotIn("systemctl", result.stdout)
        self.assertIn("ownership labels do not match", result.stderr)

    def test_preflight_requires_an_exact_unit_and_container_state_pair(self):
        result = self.run_script(
            """
            fake_unit_state=active
            container_state=running
            quadlet_unit_state() { printf '%s\n' "$fake_unit_state"; }
            podman_no_notify() {
              case "$container_state" in absent) return 1 ;; *) return 0 ;; esac
            }
            quadlet_container_labeled() { return 0; }
            quadlet_container_running_and_labeled() { [ "$container_state" = running ]; }

            set +e
            quadlet_runtime_preflight_recreate_status
            status=$?
            printf 'active-running:%s\n' "$status"

            fake_unit_state=inactive
            quadlet_runtime_preflight_recreate_status
            status=$?
            printf 'inactive-running:%s\n' "$status"

            container_state=absent
            quadlet_runtime_preflight_recreate_status
            status=$?
            printf 'inactive-absent:%s\n' "$status"

            fake_unit_state=active
            quadlet_runtime_preflight_recreate_status
            status=$?
            set -e
            printf 'active-absent:%s\n' "$status"
            """
        )
        self.assertEqual(
            [
                "active-running:1",
                "inactive-running:0",
                "inactive-absent:1",
                "active-absent:0",
            ],
            result.stdout.splitlines(),
        )


if __name__ == "__main__":
    unittest.main()
