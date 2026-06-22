import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "data-migrator.py"
spec = importlib.util.spec_from_file_location("data_migrator", MODULE_PATH)
data_migrator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(data_migrator)


class IncusPlanningTest(unittest.TestCase):
    def test_incus_controller_wraps_client_command(self):
        args = SimpleNamespace(incus_controller_host="abird-nest")

        self.assertEqual(
            data_migrator.via_incus_controller(
                args, ["incus", "list", "--project", "abird"]
            ),
            ["ssh", "abird-nest", "incus list --project abird"],
        )

    def test_local_incus_command_is_unchanged(self):
        args = SimpleNamespace(incus_controller_host=None)

        self.assertEqual(
            data_migrator.via_incus_controller(args, ["incus", "list"]),
            ["incus", "list"],
        )

    def test_incus_copy_without_projects_uses_controller_default_project(self):
        args = SimpleNamespace(
            source_project=None,
            target_project=None,
            incus_remote="local",
            target_incus_remote="local",
            incus_instance="old",
            target_instance="new",
            target_storage_pool="default",
            incus_copy_mode="pull",
            incus_stateless=True,
            incus_allow_inconsistent=True,
        )

        with mock.patch.object(data_migrator, "run_incus") as run_incus:
            data_migrator.incus_copy_instance(args)

        run_incus.assert_called_once_with(
            args,
            [
                "incus",
                "copy",
                "old",
                "new",
                "--storage",
                "default",
                "--mode",
                "pull",
                "--stateless",
                "--allow-inconsistent",
            ],
        )

    def test_incus_copy_adds_target_project_only_when_cross_project(self):
        args = SimpleNamespace(
            source_project="abird",
            target_project="abird-stage",
            incus_remote="local",
            target_incus_remote="local",
            incus_instance="old",
            target_instance="new",
            target_storage_pool="default",
            incus_copy_mode="pull",
            incus_stateless=True,
            incus_allow_inconsistent=False,
        )

        with mock.patch.object(data_migrator, "run_incus") as run_incus:
            data_migrator.incus_copy_instance(args, refresh=True)

        run_incus.assert_called_once_with(
            args,
            [
                "incus",
                "--project",
                "abird",
                "copy",
                "old",
                "new",
                "--storage",
                "default",
                "--mode",
                "pull",
                "--target-project",
                "abird-stage",
                "--refresh",
                "--refresh-exclude-older",
                "--stateless",
            ],
        )

    def test_refresh_guard_accepts_matching_marker(self):
        args = SimpleNamespace(
            incus_instance="old",
            source_project=None,
            incus_remote="local",
            force_refresh_existing=False,
            target_instance="new",
        )
        target = {
            "metadata": {
                "config": {
                    "user.data-migrator.source-instance": "old",
                    "user.data-migrator.source-project": "",
                    "user.data-migrator.source-remote": "local",
                }
            }
        }

        data_migrator.ensure_refresh_target_matches(args, target)

    def test_refresh_guard_rejects_unmarked_target(self):
        args = SimpleNamespace(
            incus_instance="old",
            source_project=None,
            incus_remote="local",
            force_refresh_existing=False,
            target_instance="new",
        )

        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                data_migrator.ensure_refresh_target_matches(
                    args, {"metadata": {"config": {}}}
                )

    def test_refresh_guard_can_be_forced(self):
        args = SimpleNamespace(
            incus_instance="old",
            source_project=None,
            incus_remote="local",
            force_refresh_existing=True,
            target_instance="new",
        )

        with redirect_stderr(io.StringIO()):
            data_migrator.ensure_refresh_target_matches(
                args, {"metadata": {"config": {}}}
            )

    def test_mark_refresh_target_sets_source_marker(self):
        args = SimpleNamespace(
            target_project=None,
            target_incus_remote="local",
            target_instance="new",
            incus_instance="old",
            source_project=None,
            incus_remote="local",
        )

        with mock.patch.object(data_migrator, "run_incus") as run_incus:
            data_migrator.mark_refresh_target(args)

        run_incus.assert_called_once_with(
            args,
            [
                "incus",
                "config",
                "set",
                "new",
                "user.data-migrator.source-instance=old",
                "user.data-migrator.source-project=",
                "user.data-migrator.source-remote=local",
            ],
        )

    def test_root_disk_pool_uses_expanded_devices(self):
        instance = {
            "metadata": {
                "expanded_devices": {
                    "root": {
                        "type": "disk",
                        "path": "/",
                        "pool": "fast",
                    }
                }
            }
        }

        self.assertEqual(data_migrator.root_disk_pool(instance), "fast")

    def test_btrfs_fast_path_requires_same_remote_pool_and_driver(self):
        args = SimpleNamespace(
            incus_migration_mode="auto",
            incus_remote="local",
            target_incus_remote="local",
            target_storage_pool=None,
            dry_run=False,
        )
        instance = {
            "metadata": {
                "expanded_devices": {
                    "root": {
                        "type": "disk",
                        "path": "/",
                        "pool": "default",
                    }
                }
            }
        }

        with mock.patch.object(
            data_migrator, "storage_pool_driver", return_value="btrfs"
        ):
            self.assertTrue(data_migrator.is_fast_incus_path(args, instance))

    def test_non_btrfs_storage_uses_fallback(self):
        args = SimpleNamespace(
            incus_migration_mode="auto",
            incus_remote="local",
            target_incus_remote="local",
            target_storage_pool=None,
            dry_run=False,
        )
        instance = {
            "metadata": {
                "expanded_devices": {
                    "root": {
                        "type": "disk",
                        "path": "/",
                        "pool": "default",
                    }
                }
            }
        }

        with mock.patch.object(
            data_migrator, "storage_pool_driver", return_value="dir"
        ):
            self.assertFalse(data_migrator.is_fast_incus_path(args, instance))


class TarFallbackTest(unittest.TestCase):
    def test_tar_excludes_support_relative_patterns(self):
        self.assertEqual(
            data_migrator.tar_excludes(["/tmp/", "/.podman-compose/"]),
            [
                "--exclude=tmp",
                "--exclude=./tmp",
                "--exclude=.podman-compose",
                "--exclude=./.podman-compose",
            ],
        )

    def test_clean_command_rejects_root(self):
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                data_migrator.safe_clean_command("/")


class DeployPlanningTest(unittest.TestCase):
    def test_bootstrap_override_is_service_owned_and_host_encoded(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            bootstrap_dir = repo_root / "lib" / "services" / "migration-manager"

            with mock.patch.object(data_migrator, "read_bootstrap_hosts", return_value={}):
                data_migrator.write_bootstrap_hosts(repo_root, 'abird-"corp"')

            self.assertEqual(
                (bootstrap_dir / "bootstrap-hosts.nix").read_text(encoding="utf-8"),
                '{\n  "abird-\\"corp\\"" = {\n    "state" = "on";\n  };\n}\n',
            )

    def test_bootstrap_override_preserves_other_hosts(self):
        hosts = {
            "abird-data": {"state": "off"},
            "abird-id": {"on": False},
        }

        self.assertEqual(
            data_migrator.render_bootstrap_hosts(
                data_migrator.updated_bootstrap_hosts(hosts, "abird-corp")
            ),
            "\n".join(
                [
                    "{",
                    '  "abird-corp" = {',
                    '    "state" = "on";',
                    "  };",
                    '  "abird-data" = {',
                    '    "state" = "off";',
                    "  };",
                    '  "abird-id" = {',
                    '    "on" = false;',
                    "  };",
                    "}",
                    "",
                ]
            ),
        )

    def test_bootstrap_override_replaces_legacy_on_for_target(self):
        self.assertEqual(
            data_migrator.updated_bootstrap_hosts(
                {"abird-corp": {"on": False}}, "abird-corp"
            ),
            {"abird-corp": {"state": "on"}},
        )

    def test_read_bootstrap_hosts_uses_nix_eval_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            bootstrap_path = Path(tmp) / "bootstrap-hosts.nix"
            bootstrap_path.write_text("{}", encoding="utf-8")

            with mock.patch.object(
                data_migrator,
                "run_capture",
                return_value='{"abird-id":{"state":"off"}}',
            ) as run_capture:
                self.assertEqual(
                    data_migrator.read_bootstrap_hosts(bootstrap_path),
                    {"abird-id": {"state": "off"}},
                )

        run_capture.assert_called_once_with(
            ["nix", "eval", "--json", "--file", bootstrap_path]
        )

    def test_target_resume_deploys_normal_generation(self):
        args = SimpleNamespace(
            skip_deploy=False,
            nixbot_goal="switch",
            nixbot_dry=False,
            repo_root=Path("/repo"),
            dry_run=False,
        )

        with mock.patch.object(data_migrator, "run") as run:
            data_migrator.deploy_target_resumed(args, "abird-corp")

        self.assertEqual(
            run.call_args_list,
            [
                mock.call(
                    [
                        "nixbot",
                        "deploy",
                        "--hosts",
                        "abird-corp",
                        "--dirty-staged",
                        "--force",
                        "--goal",
                        "switch",
                    ],
                    cwd=Path("/repo"),
                    dry_run=False,
                ),
                mock.call(
                    [
                        "migratorctl",
                        "remote",
                        "off",
                        "--host",
                        "abird-corp",
                        "--repo-root",
                        "/repo",
                    ],
                    cwd=Path("/repo"),
                    dry_run=False,
                ),
            ],
        )

    def test_target_prepare_stages_generated_gate_before_deploy(self):
        args = SimpleNamespace(
            skip_deploy=False,
            nixbot_goal="switch",
            nixbot_dry=False,
            repo_root=Path("/repo"),
            dry_run=False,
            keep_workdir=False,
        )

        with (
            mock.patch.object(data_migrator.os, "getpid", return_value=123),
            mock.patch.object(data_migrator, "write_bootstrap_hosts") as write_hosts,
            mock.patch.object(data_migrator.shutil, "rmtree") as rmtree,
            mock.patch.object(data_migrator, "run") as run,
        ):
            data_migrator.deploy_target_prepared(args, "abird-corp")

        worktree = Path("/repo/tmp/data-migrator.123/abird-corp-prepare")
        write_hosts.assert_called_once_with(worktree, "abird-corp")
        rmtree.assert_called_once_with(
            Path("/repo/tmp/data-migrator.123"),
            ignore_errors=True,
        )
        self.assertEqual(
            run.call_args_list,
            [
                mock.call(
                    ["git", "worktree", "add", "--detach", worktree, "HEAD"],
                    cwd=Path("/repo"),
                    dry_run=False,
                ),
                mock.call(
                    ["git", "add", "lib/services/migration-manager/bootstrap-hosts.nix"],
                    cwd=worktree,
                ),
                mock.call(
                    [
                        "nixbot",
                        "deploy",
                        "--hosts",
                        "abird-corp",
                        "--dirty-staged",
                        "--force",
                        "--goal",
                        "switch",
                    ],
                    cwd=worktree,
                    dry_run=False,
                ),
                mock.call(
                    ["git", "worktree", "remove", "--force", worktree],
                    cwd=Path("/repo"),
                ),
            ],
        )

    def test_no_start_target_requires_no_resume_target(self):
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                data_migrator.parse_args(
                    [
                        "--profile",
                        "abird-corp",
                        "--source-project",
                        "abird",
                        "--target-project",
                        "abird-stage",
                        "--no-start-target",
                    ]
                )

    def test_no_start_target_allows_no_resume_target(self):
        args = data_migrator.parse_args(
            [
                "--profile",
                "abird-corp",
                "--source-project",
                "abird",
                "--target-project",
                "abird-stage",
                "--no-start-target",
                "--no-resume-target",
            ]
        )

        self.assertTrue(args.no_start_target)
        self.assertTrue(args.no_resume_target)


if __name__ == "__main__":
    unittest.main()
