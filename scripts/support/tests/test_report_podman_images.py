#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest
from unittest import mock


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "report-podman-images.py"
SPEC = importlib.util.spec_from_file_location("report_podman_images", SCRIPT_PATH)
report_podman_images = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report_podman_images)


class ReportPodmanImagesTest(unittest.TestCase):
    def test_parse_image_ref_ignores_parameter_expansion_colon(self):
        parsed = report_podman_images.parse_image_ref(
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

    def test_parameterized_tag_reports_as_variable_tag(self):
        line = report_podman_images.image_report_line(
            "ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}",
            False,
        )

        self.assertEqual(
            line,
            "- ghcr.io/immich-app/immich-server: ${IMMICH_VERSION:-release} [variable tag]",
        )

    def test_release_tag_reports_as_floating_tag(self):
        line = report_podman_images.image_report_line(
            "ghcr.io/immich-app/immich-server:release",
            False,
        )

        self.assertEqual(
            line,
            "- ghcr.io/immich-app/immich-server: release [floating tag]",
        )

    def test_immich_uses_latest_github_release_tag(self):
        with (
            mock.patch.object(
                report_podman_images,
                "request_json",
                return_value={"tag_name": "v3.0.2"},
            ),
            mock.patch.object(
                report_podman_images,
                "registry_tags",
                return_value=["v1.91.1"],
            ),
        ):
            latest = report_podman_images.latest_known_tag(
                "ghcr.io",
                "immich-app/immich-server",
                "v2.0.0",
            )

        self.assertEqual(latest, "v3.0.2")

    def test_timescale_pg_tag_compares_within_pg_major(self):
        latest = report_podman_images.latest_comparable_tag(
            "pg18.4-ts2.28.1",
            [
                "pg18.4-ts2.28.1",
                "pg18.4-ts2.28.2",
                "pg18.4-ts2.28.2-all",
                "pg19.1-ts2.29.0",
            ],
        )

        self.assertEqual(latest, "pg18.4-ts2.28.2")

    def test_collect_images_keeps_instance_boundary(self):
        contexts = report_podman_images.collect_images_by_context_and_instance(
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
        contexts = report_podman_images.collect_images_by_context_and_instance(
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
        line = report_podman_images.prefix_image_report_line(
            "- louislam/dockge: 1.5.0 [latest]",
            "dockge",
            False,
        )

        self.assertEqual(line, "- dockge | louislam/dockge: 1.5.0 [latest]")


if __name__ == "__main__":
    unittest.main()
