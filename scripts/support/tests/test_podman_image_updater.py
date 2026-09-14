#!/usr/bin/env python3
import importlib.util
import pathlib
import tempfile
import unittest
from unittest import mock


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "podman-image-updater.py"
SPEC = importlib.util.spec_from_file_location("podman_image_updater", SCRIPT_PATH)
podman_image_updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(podman_image_updater)


class PodmanImageUpdaterTest(unittest.TestCase):
    def test_parse_image_ref_ignores_parameter_expansion_colon(self):
        parsed = podman_image_updater.parse_image_ref(
            "ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}"
        )

        self.assertEqual(
            parsed,
            (
                "ghcr.io",
                "immich-app/immich-server",
                "ghcr.io/immich-app/immich-server",
                "${IMMICH_VERSION:-release}",
                None,
            ),
        )

    def test_parse_explicit_docker_official_image_adds_library_namespace(self):
        parsed = podman_image_updater.parse_image_ref("docker.io/postgres:16-alpine")

        self.assertEqual(parsed[0], "docker.io")
        self.assertEqual(parsed[1], "library/postgres")
        self.assertEqual(parsed[2], "docker.io/postgres")

    def test_parameterized_tag_reports_as_variable_tag(self):
        line = podman_image_updater.image_report_line(
            "ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}",
            False,
        )

        self.assertEqual(
            line,
            "- ghcr.io/immich-app/immich-server: ${IMMICH_VERSION:-release} [variable tag]",
        )

    def test_release_tag_reports_as_floating_tag(self):
        line = podman_image_updater.image_report_line(
            "ghcr.io/immich-app/immich-server:release",
            False,
        )

        self.assertEqual(
            line,
            "- ghcr.io/immich-app/immich-server: release [floating tag]",
        )

    def test_stable_tag_reports_as_floating_tag(self):
        line = podman_image_updater.image_report_line(
            "docker.io/jitsi/jvb:stable",
            False,
        )

        self.assertEqual(line, "- docker.io/jitsi/jvb: stable [floating tag]")

    def test_digest_reports_as_pinned_without_claiming_latest(self):
        line = podman_image_updater.image_report_line(
            "docker.io/jitsi/jvb@sha256:abc123",
            False,
        )

        self.assertEqual(
            line,
            "- docker.io/jitsi/jvb: latest@sha256:abc123 [digest pinned]",
        )

    def test_immich_uses_latest_github_release_tag(self):
        with (
            mock.patch.object(
                podman_image_updater,
                "request_json",
                return_value={"tag_name": "v3.0.2"},
            ),
            mock.patch.object(
                podman_image_updater,
                "registry_tags",
                return_value=["v1.91.1"],
            ),
        ):
            latest = podman_image_updater.latest_known_tag(
                "ghcr.io",
                "immich-app/immich-server",
                "v2.0.0",
            )

        self.assertEqual(latest, "v3.0.2")

    def test_stirling_release_strips_non_registry_v_prefix(self):
        with mock.patch.object(
            podman_image_updater,
            "request_json",
            return_value={"tag_name": "v2.14.3"},
        ):
            latest = podman_image_updater.latest_known_tag(
                "docker.stirlingpdf.com",
                "stirlingtools/stirling-pdf",
                "2.14.2",
            )

        self.assertEqual(latest, "2.14.3")

    def test_nginx_updates_within_even_minor_stable_releases(self):
        with mock.patch.object(
            podman_image_updater,
            "registry_tags",
            return_value=["1.30.3", "1.30.4", "1.31.5", "1.30.4-alpine"],
        ):
            latest = podman_image_updater.latest_known_tag(
                "registry-1.docker.io",
                "library/nginx",
                "1.30.3",
            )

        self.assertEqual(latest, "1.30.4")

    def test_postgres_preserves_selected_major_release_track(self):
        with mock.patch.object(
            podman_image_updater,
            "registry_tags",
            return_value=["16-alpine", "17-alpine", "18-alpine"],
        ):
            latest = podman_image_updater.latest_known_tag(
                "docker.io",
                "library/postgres",
                "16-alpine",
            )

        self.assertEqual(latest, "16-alpine")

    def test_timescale_pg_tag_compares_within_pg_major(self):
        latest = podman_image_updater.latest_comparable_tag(
            "pg18.4-ts2.28.1",
            [
                "pg18.4-ts2.28.1",
                "pg18.4-ts2.28.2",
                "pg18.4-ts2.28.2-all",
                "pg19.1-ts2.29.0",
            ],
        )

        self.assertEqual(latest, "pg18.4-ts2.28.2")

    def test_stable_build_tag_compares_build_numbers(self):
        latest = podman_image_updater.latest_comparable_tag(
            "stable-10978",
            [
                "stable",
                "stable-10532-1",
                "stable-10978",
                "stable-11031",
                "unstable-12000",
            ],
        )

        self.assertEqual(latest, "stable-11031")

    def test_stable_build_tag_compares_release_revisions(self):
        latest = podman_image_updater.latest_comparable_tag(
            "stable-10532",
            ["stable-10532", "stable-10532-1"],
        )

        self.assertEqual(latest, "stable-10532-1")

    def test_stable_build_image_reports_new_release(self):
        with mock.patch.object(
            podman_image_updater,
            "registry_tags",
            return_value=["stable", "stable-10978", "stable-11031"],
        ):
            line = podman_image_updater.image_report_line(
                "docker.io/jitsi/jvb:stable-10978",
                False,
            )

        self.assertEqual(
            line,
            "- docker.io/jitsi/jvb: stable-10978 -> stable-11031",
        )

    def test_collect_images_keeps_instance_boundary(self):
        contexts = podman_image_updater.collect_images_by_context_and_instance(
            {
                "nixos-host": {
                    "hostName": "pvl-x2",
                    "stackName": "pvl",
                    "podmanSources": {
                        "pvl": {
                            "dockge": {
                                "source": {
                                    "services": {
                                        "dockge": {
                                            "image": "louislam/dockge:1.5.0",
                                        },
                                    },
                                },
                            },
                            "immich": {
                                "source": """
                                  services:
                                    valkey:
                                      image: docker.io/valkey/valkey:9
                                """,
                            },
                        },
                    },
                },
            },
        )

        self.assertEqual(
            contexts,
            {
                ("pvl", "pvl-x2", "pvl"): {
                    "dockge": ["louislam/dockge:1.5.0"],
                    "immich": ["docker.io/valkey/valkey:9"],
                },
            },
        )

    def test_collect_images_ignores_generated_nix_local_images(self):
        contexts = podman_image_updater.collect_images_by_context_and_instance(
            {
                "nixos-host": {
                    "hostName": "pvl-x2",
                    "stackName": "pvl",
                    "podmanSources": {
                        "pvl": {
                            "local": {
                                "source": """
                                  services:
                                    app:
                                      image: localhost/nix-local/image:abc123
                                """,
                            },
                            "remote": {
                                "source": """
                                  services:
                                    app:
                                      image: docker.io/library/nginx:1.29
                                """,
                            },
                        },
                    },
                },
            },
        )

        self.assertEqual(
            contexts,
            {
                ("pvl", "pvl-x2", "pvl"): {
                    "remote": ["docker.io/library/nginx:1.29"],
                },
            },
        )

    def test_prefix_image_report_line_adds_instance_boundary(self):
        line = podman_image_updater.prefix_image_report_line(
            "- louislam/dockge: 1.5.0 [latest]",
            "dockge",
            False,
        )

        self.assertEqual(line, "- dockge | louislam/dockge: 1.5.0 [latest]")

    def test_collect_source_files_maps_flake_definitions(self):
        with tempfile.TemporaryDirectory() as directory:
            repo_root = pathlib.Path(directory)
            source_dir = repo_root / "hosts/example/services/app"
            source_dir.mkdir(parents=True)
            source_file = source_dir / "default.nix"
            source_file.write_text("{}\n")
            sources = {
                "host": {
                    "hostName": "example",
                    "stackName": "pvl",
                    "repoSource": "/nix/store/hash-source",
                    "definitions": [
                        {
                            "file": "/nix/store/hash-source/hosts/example/services/app",
                            "instances": {"pvl": ["app"]},
                        }
                    ],
                    "podmanSources": {},
                }
            }

            files = podman_image_updater.collect_source_files_by_context_and_instance(
                sources, repo_root
            )

        self.assertEqual(files, {("pvl", "example", "pvl"): {"app": [source_file]}})

    def test_plan_updates_exact_image_declaration(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            source_file.write_text(
                "source = ''\n  image: docker.io/example/app:1.0.0\n'';\n"
            )
            context = ("pvl", "host", "pvl")
            contexts = {context: {"app": ["docker.io/example/app:1.0.0"]}}
            source_files = {context: {"app": [source_file]}}
            checks = {
                "docker.io/example/app:1.0.0": podman_image_updater.ImageCheck(
                    "docker.io/example/app:1.0.0",
                    "docker.io/example/app",
                    "1.0.0",
                    "1.1.0",
                    "update",
                )
            }

            edits, originals, errors = podman_image_updater.plan_updates(
                contexts, source_files, checks
            )
            updated = podman_image_updater.updated_contents(edits, originals)

        self.assertEqual(errors, [])
        self.assertEqual(len(edits), 1)
        self.assertIn("docker.io/example/app:1.1.0", updated[source_file])

    def test_plan_updates_deduplicates_shared_version_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            source_file.write_text(
                'let version = "v3.0.2"; in ""\n'
                "  image: ghcr.io/example/server:${version}\n"
                "  image: ghcr.io/example/worker:${version}\n"
            )
            context = ("pvl", "host", "pvl")
            server = "ghcr.io/example/server:v3.0.2"
            worker = "ghcr.io/example/worker:v3.0.2"
            contexts = {context: {"app": [server, worker]}}
            source_files = {context: {"app": [source_file]}}
            checks = {
                ref: podman_image_updater.ImageCheck(
                    ref, ref.rsplit(":", 1)[0], "v3.0.2", "v3.2.0", "update"
                )
                for ref in (server, worker)
            }

            edits, originals, errors = podman_image_updater.plan_updates(
                contexts, source_files, checks
            )
            updated = podman_image_updater.updated_contents(edits, originals)

        self.assertEqual(errors, [])
        self.assertEqual(len(edits), 1)
        self.assertIn('version = "v3.2.0"', updated[source_file])

    def test_plan_updates_quoted_image_variable(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            ref = "docker.io/example/app:1.0.0"
            source_file.write_text(f'let image = "{ref}"; in "image: ${{image}}\\n"\n')
            context = ("pvl", "host", "pvl")
            check = podman_image_updater.ImageCheck(
                ref, "docker.io/example/app", "1.0.0", "1.1.0", "update"
            )

            edits, originals, errors = podman_image_updater.plan_updates(
                {context: {"app": [ref]}},
                {context: {"app": [source_file]}},
                {ref: check},
            )
            updated = podman_image_updater.updated_contents(edits, originals)

        self.assertEqual(errors, [])
        self.assertEqual(len(edits), 1)
        self.assertIn('image = "docker.io/example/app:1.1.0"', updated[source_file])

    def test_plan_updates_rejects_ambiguous_owners(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source_files = [root / "one.nix", root / "two.nix"]
            ref = "docker.io/example/app:1.0.0"
            for source_file in source_files:
                source_file.write_text(f"source = ''\n  image: {ref}\n'';\n")
            context = ("pvl", "host", "pvl")
            check = podman_image_updater.ImageCheck(
                ref, "docker.io/example/app", "1.0.0", "1.1.0", "update"
            )

            _, _, errors = podman_image_updater.plan_updates(
                {context: {"app": [ref]}},
                {context: {"app": source_files}},
                {ref: check},
            )

        self.assertEqual(len(errors), 1)
        self.assertIn("declaration is ambiguous", errors[0])

    def test_apply_updates_is_atomic_and_preserves_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            source_file = pathlib.Path(directory) / "default.nix"
            original = "image: docker.io/example/app:1.0.0\n"
            source_file.write_text(original)
            source_file.chmod(0o640)
            start = original.index("1.0.0")
            edit = podman_image_updater.TextEdit(
                source_file, start, start + len("1.0.0"), "1.1.0"
            )

            podman_image_updater.apply_updates([edit], {source_file: original})

            self.assertEqual(
                source_file.read_text(), "image: docker.io/example/app:1.1.0\n"
            )
            self.assertEqual(source_file.stat().st_mode & 0o777, 0o640)

    def test_apply_updates_rolls_back_partial_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            first = root / "first.nix"
            second = root / "second.nix"
            first.write_text("old-first\n")
            second.write_text("old-second\n")
            originals = {first: first.read_text(), second: second.read_text()}
            edits = [
                podman_image_updater.TextEdit(first, 0, 3, "new"),
                podman_image_updater.TextEdit(second, 0, 3, "new"),
            ]
            real_replace = podman_image_updater.os.replace
            calls = 0

            def fail_second_replacement(source, destination):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("simulated failure")
                return real_replace(source, destination)

            with (
                mock.patch.object(
                    podman_image_updater.os,
                    "replace",
                    side_effect=fail_second_replacement,
                ),
                self.assertRaisesRegex(RuntimeError, "was rolled back"),
            ):
                podman_image_updater.apply_updates(edits, originals)

            self.assertEqual(first.read_text(), "old-first\n")
            self.assertEqual(second.read_text(), "old-second\n")


if __name__ == "__main__":
    unittest.main()
