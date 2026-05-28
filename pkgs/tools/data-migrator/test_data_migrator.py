import importlib.util
import io
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).with_name("data-migrator.py")
spec = importlib.util.spec_from_file_location("data_migrator", MODULE_PATH)
data_migrator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(data_migrator)


class IncusPlanningTest(unittest.TestCase):
    def test_incus_controller_wraps_client_command(self):
        args = SimpleNamespace(incus_controller_host="incus-parent")

        self.assertEqual(
            data_migrator.via_incus_controller(
                args, ["incus", "list", "--project", "app"]
            ),
            ["ssh", "incus-parent", "incus list --project app"],
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
            source_project="app",
            target_project="app-stage",
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
                "app",
                "copy",
                "old",
                "new",
                "--storage",
                "default",
                "--mode",
                "pull",
                "--target-project",
                "app-stage",
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


class PathMappingTest(unittest.TestCase):
    def test_migrate_path_defaults_to_root_bases(self):
        args = SimpleNamespace(
            effective_transport="rsync",
            rsync_ssh=None,
            source_host="source",
            target_host="target",
            target_dir=None,
            target_base=None,
            source_base=None,
            remote_sudo=False,
            source_rsync_path=None,
            copy_mode="pull",
            dry_run=False,
        )
        plan = {}
        entry = {"path": "/var/lib/app", "excludes": []}

        with (
            mock.patch.object(data_migrator, "remote_shell") as remote_shell,
            mock.patch.object(data_migrator, "run"),
        ):
            data_migrator.migrate_one_path(args, plan, entry, "seed", [])

        remote_shell.assert_any_call(
            "target", "install -d /var/lib/app/", dry_run=False
        )


if __name__ == "__main__":
    unittest.main()
