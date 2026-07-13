import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class HostManagerScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.script = cls.repo_root / "pkgs/tools/host-manager/host-manager.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="host-manager-test.", dir=self.tmp_root))
        self.test_script = self.work_dir / "host-manager-test-source.sh"
        source = self.script.read_text(encoding="utf-8")
        self.test_script.write_text(
            source.replace('\nmain "$@"\n', "\n"),
            encoding="utf-8",
        )
        self.fake_repo = self.work_dir / "repo"
        (self.fake_repo / "pkgs").mkdir(parents=True)
        (self.fake_repo / "hosts").mkdir()
        (self.fake_repo / "data/secrets/globals/machine").mkdir(parents=True)
        (self.fake_repo / "flake.nix").write_text("{}\n", encoding="utf-8")
        (self.fake_repo / "pkgs/manifest.nix").write_text("{}\n", encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def run_script(self, body, *, check=True):
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
            cwd=self.fake_repo,
            env=os.environ.copy() | {"HOST_MANAGER_REPO_ROOT": str(self.fake_repo)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_parse_and_validate_common_for_incus_generation(self):
        (self.fake_repo / "hosts/parent").mkdir()
        (self.fake_repo / "hosts/parent/incus.nix").write_text(
            "{...}: { services.incus-manager.default.instances = {}; }\n",
            encoding="utf-8",
        )
        result = self.run_script(
            """
            init_vars
            stack_exists() { [ "$1" = "abird" ]; }
            parse_args generate child-1 --stack abird --system incus --incus-host parent --incus-project lab --incus-ipv4 10.10.30.44
            validate_args
            jq -n \
              --arg action "$ACTION" \
              --arg host "$HOST" \
              --arg stack "$HOST_STACK" \
              --arg system "$HOST_SYSTEM" \
              --arg parent "$INCUS_HOST" \
              --arg project "$INCUS_PROJECT" \
              --arg ipv4 "$INCUS_IPV4" \
              --arg target "$NIXBOT_TARGET" \
              --arg hostDir "$HOST_DIR" \
              '{action:$action,host:$host,stack:$stack,system:$system,parent:$parent,project:$project,ipv4:$ipv4,target:$target,hostDir:$hostDir}'
            """
        )

        self.assertEqual(
            {
                "action": "generate",
                "host": "child-1",
                "stack": "abird",
                "system": "incus",
                "parent": "parent",
                "project": "lab",
                "ipv4": "10.10.30.44",
                "target": "",
                "hostDir": str(self.fake_repo / "hosts/child-1"),
            },
            json.loads(result.stdout),
        )

    def test_validation_rejects_bad_host_ipv4_and_store_paths(self):
        bad_host = self.run_script(
            """
            init_vars
            parse_args generate '-bad'
            validate_common
            """,
            check=False,
        )
        self.assertNotEqual(0, bad_host.returncode)
        self.assertIn("HOST must start and end", bad_host.stderr)

        bad_ip = self.run_script(
            """
            init_vars
            HOST=child
            INCUS_IPV4=10.10.30.999
            validate_common
            """,
            check=False,
        )
        self.assertNotEqual(0, bad_ip.returncode)
        self.assertIn("--incus-ipv4 must be an IPv4 address", bad_ip.stderr)

        bad_store = self.run_script(
            """
            init_vars
            validate_store_dir 'bad path'
            """,
            check=False,
        )
        self.assertNotEqual(0, bad_store.returncode)
        self.assertIn("must not contain whitespace", bad_store.stderr)

    def test_staging_paths_are_confined_to_repo(self):
        result = self.run_script(
            """
            init_vars
            RUN_DIR="$PWD/tmp-run"
            STAGE_DIR="$RUN_DIR/staged"
            mkdir -p "$STAGE_DIR"
            stage_target_path "$REPO_ROOT/hosts/new/default.nix"
            """,
        )
        self.assertEqual(
            str(self.fake_repo / "tmp-run/staged/hosts/new/default.nix"),
            result.stdout.strip(),
        )

        outside = self.run_script(
            """
            init_vars
            RUN_DIR="$PWD/tmp-run"
            STAGE_DIR="$RUN_DIR/staged"
            target_rel_path /tmp/outside.nix
            """,
            check=False,
        )
        self.assertNotEqual(0, outside.returncode)
        self.assertIn("Refusing to stage path outside repo", outside.stderr)

    def test_text_attrset_insertion_and_removal_preserve_surrounding_content(self):
        source = self.work_dir / "input.nix"
        entry = self.work_dir / "entry.nix"
        inserted = self.work_dir / "inserted.nix"
        removed = self.work_dir / "removed.nix"
        source.write_text(
            textwrap.dedent(
                """
                {
                  hosts = {
                    old = {
                      value = 1;
                    };
                  };
                  keep = true;
                }
                """
            ).lstrip(),
            encoding="utf-8",
        )
        entry.write_text(
            textwrap.dedent(
                """
                    new-host = {
                      value = 2;
                    };
                """
            ),
            encoding="utf-8",
        )

        self.run_script(
            f"""
            init_vars
            insert_into_attrset {entry} {source} {inserted} '^  hosts = [{{]$' '^  [}}];$'
            remove_attr_block old {inserted} {removed}
            cat {removed}
            """
        )

        output = removed.read_text(encoding="utf-8")
        self.assertIn("new-host = {", output)
        self.assertIn("keep = true;", output)
        self.assertNotIn("old = {", output)

    def test_nix_attr_key_and_regex_handle_quoted_host_names(self):
        result = self.run_script(
            """
            init_vars
            nix_attr_key alpha-1; printf '\n'
            nix_attr_key 'bad.name'; printf '\n'
            nix_attr_assignment_regex 'bad.name'; printf '\n'
            """
        )

        lines = result.stdout.splitlines()
        self.assertEqual("alpha-1", lines[0])
        self.assertEqual('"bad.name"', lines[1])
        self.assertIn('"bad\\.name"', lines[2])

    def test_parse_remote_operations(self):
        result = self.run_script(
            """
            init_vars
            parse_args ssh --host=app -- -tt journalctl
            printf '%s %s %s\\n' "$ACTION" "$HOST" "${SSH_EXTRA_ARGS[*]}"
            init_vars
            parse_args reboot app --dry-run
            printf '%s %s %s\\n' "$ACTION" "$HOST" "$DRY_RUN"
            init_vars
            parse_args reboot --host=all --jobs=3 --dry-run
            printf '%s %s %s %s\\n' "$ACTION" "$HOST" "$HOST_JOBS" "$DRY_RUN"
            init_vars
            parse_args gc app --delete-older-than 14d --dry-run
            printf '%s %s %s %s\\n' "$ACTION" "$HOST" "$DELETE_OLDER_THAN" "$DRY_RUN"
            init_vars
            parse_args clean:podman app --force-held --yes
            printf '%s %s %s %s\\n' "$ACTION" "$HOST" "$FORCE_HELD" "$YES"
            init_vars
            parse_args clean:nixbot app --dry-run
            printf '%s %s %s\\n' "$ACTION" "$HOST" "$DRY_RUN"
            init_vars
            parse_args clean:deploy --host=all --dry-run
            printf '%s %s %s\\n' "$ACTION" "$HOST" "$DRY_RUN"
            init_vars
            parse_args clean:podman --host=all --force-held --yes
            printf '%s %s %s %s\\n' "$ACTION" "$HOST" "$FORCE_HELD" "$YES"
            init_vars
            parse_args gc --host=all --all --dry-run
            printf '%s %s %s %s\\n' "$ACTION" "$HOST" "$GC_ALL" "$DRY_RUN"
            init_vars
            parse_args logs app --lines 50 --follow
            printf '%s %s %s %s %s\\n' "$ACTION" "$HOST" "$SERVICE_NAME" "$LOG_LINES" "$LOG_FOLLOW"
            init_vars
            parse_args logs app --service stalwart --lines 50 --follow
            printf '%s %s %s %s %s\\n' "$ACTION" "$HOST" "$SERVICE_NAME" "$LOG_LINES" "$LOG_FOLLOW"
            init_vars
            parse_args service logs postgres --stack pvl --lines 25 --follow --user pvl
            printf '%s %s %s %s %s %s\\n' "$ACTION" "$SERVICE_NAME" "$HOST_STACK" "$LOG_LINES" "$LOG_FOLLOW" "$LOG_USER"
            init_vars
            parse_args service start stalwart --host=app --dry-run
            printf '%s %s %s %s\\n' "$ACTION" "$SERVICE_NAME" "$HOST" "$DRY_RUN"
            init_vars
            parse_args service restart stalwart --host app --dry-run
            printf '%s %s %s %s\\n' "$ACTION" "$SERVICE_NAME" "$HOST" "$DRY_RUN"
            init_vars
            parse_args service status stalwart --host app
            printf '%s %s %s\\n' "$ACTION" "$SERVICE_NAME" "$HOST"
            """
        )

        self.assertEqual(
            [
                "ssh app -tt journalctl",
                "reboot app 1",
                "reboot all 3 1",
                "gc app 14d 1",
                "podman-clean app 1 1",
                "nixbot-clean app 1",
                "deploy-clean all 1",
                "podman-clean all 1 1",
                "gc all 1 1",
                "logs app  50 1",
                "logs app stalwart 50 1",
                "service-logs postgres pvl 25 1 pvl",
                "service-start stalwart app 1",
                "service-restart stalwart app 1",
                "service-status stalwart app",
            ],
            result.stdout.splitlines(),
        )

    def test_parse_primary_actions_accept_host_flag(self):
        result = self.run_script(
            """
            init_vars
            parse_args build --host=app --store cache
            printf '%s %s %s\\n' "$ACTION" "$HOST" "$STORE_DIR"
            init_vars
            parse_args generate --host=app --system live --disk /dev/disk/by-id/test
            printf '%s %s %s %s\\n' "$ACTION" "$HOST" "$HOST_SYSTEM" "$DISK_DEVICE"
            init_vars
            parse_args live-install --host=app --wipe-disks --dry-run
            printf '%s %s %s %s\\n' "$ACTION" "$HOST" "$WIPE_DISKS" "$DRY_RUN"
            init_vars
            parse_args delete --host=app --force
            printf '%s %s %s\\n' "$ACTION" "$HOST" "$FORCE"
            """
        )

        self.assertEqual(
            [
                f"build app {self.fake_repo}/cache",
                "generate app live /dev/disk/by-id/test",
                "live-install app 1 1",
                "delete app 1",
            ],
            result.stdout.splitlines(),
        )

    def test_register_incus_host_uses_local_lxc_profile(self):
        hosts_default = self.fake_repo / "hosts/default.nix"
        hosts_default.write_text(
            textwrap.dedent(
                """
                {
                  machineProfiles,
                  mkNixosSystem,
                  stacks,
                  ...
                }: {
                }
                """
            ).lstrip(),
            encoding="utf-8",
        )
        result = self.run_script(
            """
            init_vars
            HOST=child-1
            HOST_SYSTEM=incus
            RUN_DIR="$PWD/tmp-run"
            STAGE_DIR="$RUN_DIR/staged"
            MUTATION_LOCK_DIR="$RUN_DIR/locks"
            mkdir -p "$RUN_DIR" "$STAGE_DIR" "$MUTATION_LOCK_DIR"
            register_host
            cat "$STAGE_DIR/hosts/default.nix"
            """
        )

        self.assertIn("machineProfile = machineProfiles.incusLxc;", result.stdout)
        self.assertNotIn("machineProfiles.vm", result.stdout)

    def test_two_word_clean_aliases_are_not_supported(self):
        result = self.run_script(
            """
            init_vars
            parse_args podman clean app
            """,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Unknown action: podman", result.stderr)

    def test_all_host_sentinel_is_limited_to_maintenance_commands(self):
        result = self.run_script(
            """
            init_vars
            parse_args logs all
            validate_common
            """,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Use --host=all", result.stderr)

        clean_all = self.run_script(
            """
            init_vars
            parse_args clean:podman --all
            """,
            check=False,
        )

        self.assertNotEqual(0, clean_all.returncode)
        self.assertIn("--all is only supported by gc", clean_all.stderr)

        bad_jobs = self.run_script(
            """
            init_vars
            parse_args reboot --host=all --jobs=0
            validate_common
            """,
            check=False,
        )

        self.assertNotEqual(0, bad_jobs.returncode)
        self.assertIn("--jobs must be a positive integer", bad_jobs.stderr)

    def test_prepare_ssh_context_uses_nixbot_inventory_route(self):
        (self.fake_repo / "hosts/nixbot.nix").write_text(
            textwrap.dedent(
                """
                {
                  config.hostDefaults = {
                    operatorUser = "ops-default";
                    operatorKey = "/home/ops/.ssh/default";
                  };
                  hosts = {
                    app = {
                      target = "10.10.0.2";
                      operatorUser = "ops-app";
                      operatorKey = "/home/ops/.ssh/app";
                      proxyJump = "bastion";
                    };
                    edge = {
                      target = "edge.example";
                      proxyCommand = "cloudflared access ssh --hostname %h";
                    };
                  };
                }
                """
            ),
            encoding="utf-8",
        )

        result = self.run_script(
            """
            init_vars
            OP_USER=pvl
            prepare_ssh_context app remote
            printf 'target=%s\\n' "$REMOTE_SSH_TARGET"
            printf 'args=%s\\n' "${REMOTE_SSH_ARGS[*]}"
            prepare_ssh_context edge interactive
            printf 'target=%s\\n' "$REMOTE_SSH_TARGET"
            printf 'args=%s\\n' "${REMOTE_SSH_ARGS[*]}"
            """
        )

        output = result.stdout
        self.assertIn("target=ops-app@10.10.0.2", output)
        self.assertIn("-i /home/ops/.ssh/app -o IdentitiesOnly=yes", output)
        self.assertIn("-J bastion", output)
        self.assertIn("target=ops-default@edge.example", output)
        self.assertIn("-i /home/ops/.ssh/default -o IdentitiesOnly=yes", output)
        self.assertIn("ProxyCommand=cloudflared access ssh --hostname %h", output)

    def test_prepare_ssh_context_explicit_user_overrides_inventory_operator_user(self):
        (self.fake_repo / "hosts/nixbot.nix").write_text(
            textwrap.dedent(
                """
                {
                  config.hostDefaults = {
                    operatorUser = "ops-default";
                    operatorKey = "/home/ops/.ssh/default";
                  };
                  hosts = {
                    app = {
                      target = "10.10.0.2";
                      operatorUser = "ops-app";
                      operatorKey = "/home/ops/.ssh/app";
                    };
                  };
                }
                """
            ),
            encoding="utf-8",
        )

        result = self.run_script(
            """
            init_vars
            parse_args ssh app --user pvl
            prepare_ssh_context app remote
            printf 'target=%s\\n' "$REMOTE_SSH_TARGET"
            printf 'args=%s\\n' "${REMOTE_SSH_ARGS[*]}"
            """
        )

        output = result.stdout
        self.assertIn("target=pvl@10.10.0.2", output)
        self.assertNotIn("/home/ops/.ssh/app", output)

    def test_prepare_ssh_context_generates_inventory_proxy_config(self):
        (self.fake_repo / "hosts/nixbot.nix").write_text(
            textwrap.dedent(
                """
                {
                  config.hostDefaults = {
                    operatorUser = "ops-default";
                    operatorKey = "/home/ops/.ssh/default";
                  };
                  hosts = {
                    parent = {
                      target = "parent.example";
                      operatorUser = "ops-parent";
                      operatorKey = "/home/ops/.ssh/parent";
                      proxyCommand = "cloudflared access ssh --hostname %h";
                    };
                    app = {
                      target = "10.10.0.2";
                      proxyJump = "parent";
                    };
                  };
                }
                """
            ),
            encoding="utf-8",
        )

        result = self.run_script(
            """
            init_vars
            RUN_DIR="$PWD/tmp-run"
            mkdir -p "$RUN_DIR"
            OP_USER=pvl
            ssh_known_host_exists() {
              [ "$1" = parent ] || [ "$1" = app ]
            }
            prepare_ssh_context app remote
            printf 'target=%s\\n' "$REMOTE_SSH_TARGET"
            printf 'args=%s\\n' "${REMOTE_SSH_ARGS[*]}"
            cat "$REMOTE_SSH_CONFIG"
            """
        )

        output = result.stdout
        self.assertIn("target=host-manager-app", output)
        self.assertIn("-F", output)
        self.assertIn("Host host-manager-parent", output)
        self.assertIn("HostKeyAlias parent", output)
        self.assertIn("User ops-parent", output)
        self.assertIn("IdentityFile /home/ops/.ssh/parent", output)
        self.assertIn("IdentitiesOnly yes", output)
        self.assertIn("HostName parent.example", output)
        self.assertIn("ProxyCommand cloudflared access ssh --hostname %h", output)
        self.assertIn("Host host-manager-app", output)
        self.assertIn("HostName 10.10.0.2", output)
        self.assertIn("User ops-default", output)
        self.assertIn("IdentityFile /home/ops/.ssh/default", output)
        self.assertIn("ProxyJump host-manager-parent", output)

    def test_prepare_ssh_context_uses_nixbot_override(self):
        (self.fake_repo / "hosts/nixbot.nix").write_text(
            textwrap.dedent(
                """
                {
                  hosts = {
                    gap3-gondor = {
                      target = "z.gap3.ai";
                      proxyCommand = "cloudflared access ssh --hostname %h";
                    };
                    app = {
                      target = "10.10.30.60";
                      proxyJump = "gap3-gondor";
                    };
                  };
                }
                """
            ),
            encoding="utf-8",
        )
        (self.fake_repo / "hosts/nixbot.override.nix").write_text(
            textwrap.dedent(
                """
                {
                  config.hostDefaults = {
                    operatorUser = "pvl";
                    operatorKey = "/home/pvl/.ssh/id_ed25519";
                  };
                  hosts = {
                    pvl-x2 = {
                      target = "pvl-x2";
                      operatorKey = "/home/pvl/.ssh/pvl-x2";
                    };
                    gap3-gondor = {
                      target = "10.10.20.20";
                      proxyJump = "pvl-x2";
                      proxyCommand = null;
                    };
                  };
                }
                """
            ),
            encoding="utf-8",
        )

        result = self.run_script(
            """
            init_vars
            RUN_DIR="$PWD/tmp-run"
            mkdir -p "$RUN_DIR"
            OP_USER=pvl
            ssh_known_host_exists() {
              [ "$1" = app ] || [ "$1" = gap3-gondor ] || [ "$1" = pvl-x2 ]
            }
            prepare_ssh_context app remote
            cat "$REMOTE_SSH_CONFIG"
            """
        )

        output = result.stdout
        self.assertIn("Host host-manager-app", output)
        self.assertIn("HostKeyAlias app", output)
        self.assertIn("ProxyJump host-manager-gap3-gondor", output)
        self.assertIn("Host host-manager-gap3-gondor", output)
        self.assertIn("HostName 10.10.20.20", output)
        self.assertIn("ProxyJump host-manager-pvl-x2", output)
        self.assertIn("User pvl", output)
        self.assertIn("IdentityFile /home/pvl/.ssh/id_ed25519", output)
        self.assertIn("IdentityFile /home/pvl/.ssh/pvl-x2", output)
        self.assertNotIn("cloudflared access ssh", output)

    def test_remote_root_script_quotes_env_values(self):
        result = self.run_script(
            """
            init_vars
            prepare_ssh_context() {
              REMOTE_SSH_ARGS=(-o BatchMode=yes)
              REMOTE_SSH_TARGET=app
            }
            ssh() {
              printf 'argc=%s\\n' "$#"
              printf 'cmd=%s\\n' "$4"
              cat >/dev/null
            }
            run_remote_root_script app 'echo ok' HM_LOG_SINCE='5 minutes ago'
            """
        )

        self.assertIn("argc=4", result.stdout)
        self.assertIn("HM_LOG_SINCE=5\\ minutes\\ ago", result.stdout)

    def test_gc_and_clean_dispatch_remote_scripts_with_env(self):
        result = self.run_script(
            """
            init_vars
            HOST=app
            DRY_RUN=1
            DELETE_OLDER_THAN=21d
            run_remote_root_script() {
              printf 'remote:%s\\n' "$1"
              shift
              printf '%s\\n' "$@"
            }
            run_gc
            run_remote_clean podman
            run_remote_clean all
            """
        )

        self.assertIn("remote:app", result.stdout)
        self.assertIn("HM_DRY_RUN=1", result.stdout)
        self.assertIn("HM_DELETE_OLDER_THAN=21d", result.stdout)
        self.assertIn("HM_CLEAN_KIND=podman", result.stdout)
        self.assertIn("HM_CLEAN_KIND=all", result.stdout)

    def test_all_host_maintenance_dispatches_each_inventory_host(self):
        result = self.run_script(
            """
            init_vars
            HOST=all
            DRY_RUN=1
            HOST_JOBS=2
            maintenance_target_hosts() {
              printf '%s\\n' app db
            }
            run_remote_root_script() {
              printf 'remote:%s\\n' "$1"
              shift
              printf '%s\\n' "$@"
            }
            run_reboot
            run_gc
            run_remote_clean all
            """
        )

        self.assertEqual(6, result.stdout.count("HM_DRY_RUN=1"))
        self.assertEqual(2, result.stdout.count("HM_DELETE_OLDER_THAN=7d"))
        self.assertEqual(2, result.stdout.count("HM_CLEAN_KIND=all"))
        self.assertEqual(3, result.stdout.count("remote:app"))
        self.assertEqual(3, result.stdout.count("remote:db"))

    def test_service_logs_resolves_all_service_hosts_and_uses_remote_script(self):
        result = self.run_script(
            """
            init_vars
            SERVICE_NAME=postgres
            HOST_STACK=pvl
            LOG_LINES=25
            LOG_FOLLOW=1
            resolve_service_hosts_from_stack() {
              printf '%s\\n' pvl-x2
            }
            nixbot_host_registered() {
              [ "$1" = pvl-x2 ]
            }
            run_remote_root_script() {
              printf 'remote:%s\\n' "$1"
              shift
              printf '%s\\n' "$@"
            }
            run_service_action logs
            """
        )

        self.assertIn("remote:pvl-x2", result.stdout)
        self.assertIn("HM_LOG_SERVICE=postgres", result.stdout)
        self.assertIn("HM_LOG_LINES=25", result.stdout)
        self.assertIn("HM_LOG_FOLLOW=1", result.stdout)

    def test_reboot_and_host_logs_dispatch_remote_scripts_with_env(self):
        result = self.run_script(
            """
            init_vars
            HOST=app
            DRY_RUN=1
            LOG_LINES=75
            LOG_FOLLOW=1
            run_remote_root_script() {
              printf 'remote:%s\\n' "$1"
              shift
              printf '%s\\n' "$@"
            }
            run_reboot
            run_logs
            """
        )

        self.assertIn("remote:app", result.stdout)
        self.assertIn("HM_DRY_RUN=1", result.stdout)
        self.assertIn("HM_LOG_LINES=75", result.stdout)
        self.assertIn("HM_LOG_FOLLOW=1", result.stdout)

    def test_host_logs_service_filter_targets_only_that_host(self):
        result = self.run_script(
            """
            init_vars
            HOST=app
            SERVICE_NAME=stalwart
            LOG_LINES=75
            run_remote_root_script() {
              printf 'remote:%s\\n' "$1"
              shift
              printf '%s\\n' "$@"
            }
            run_logs
            """
        )

        self.assertIn("remote:app", result.stdout)
        self.assertIn("HM_LOG_SERVICE=stalwart", result.stdout)
        self.assertIn("HM_SERVICE_ACTION=logs", result.stdout)
        self.assertIn("HM_LOG_LINES=75", result.stdout)

    def test_service_start_dispatches_remote_script_with_action(self):
        result = self.run_script(
            """
            init_vars
            HOST=app
            SERVICE_NAME=stalwart
            DRY_RUN=1
            run_remote_root_script() {
              printf 'remote:%s\\n' "$1"
              shift
              printf '%s\\n' "$@"
            }
            run_service_action start
            run_service_action restart
            run_service_action status
            """
        )

        self.assertIn("remote:app", result.stdout)
        self.assertIn("HM_LOG_SERVICE=stalwart", result.stdout)
        self.assertIn("HM_SERVICE_ACTION=start", result.stdout)
        self.assertIn("HM_SERVICE_ACTION=restart", result.stdout)
        self.assertIn("HM_SERVICE_ACTION=status", result.stdout)
        self.assertIn("HM_DRY_RUN=1", result.stdout)

    def test_remote_service_fallback_uses_local_prefix_and_user(self):
        result = self.run_script(
            """
            init_vars
            remote_service_action_script
            """
        )

        self.assertIn('unit="pvl-${service}.service"', result.stdout)
        self.assertIn('user="${requested_user:-pvl}"', result.stdout)

    def test_generated_remote_scripts_are_valid_bash(self):
        result = self.run_script(
            """
            init_vars
            HOST=app
            SERVICE_NAME=stalwart
            DRY_RUN=1
            resolve_service_hosts_from_stack() { printf '%s\\n' app; }
            nixbot_host_registered() { [ "$1" = app ]; }
            run_remote_root_script() {
              bash -n <<<"$2"
              printf 'checked:%s\\n' "$1"
            }
            run_gc
            run_reboot
            run_remote_clean podman
            run_remote_clean nixbot
            run_remote_clean all
            run_logs
            run_service_action logs
            run_service_action start
            run_service_action restart
            run_service_action status
            """
        )

        self.assertEqual(
            [
                "checked:app",
                "checked:app",
                "checked:app",
                "checked:app",
                "checked:app",
                "checked:app",
                "checked:app",
                "checked:app",
                "checked:app",
                "checked:app",
            ],
            result.stdout.splitlines(),
        )


if __name__ == "__main__":
    unittest.main()
