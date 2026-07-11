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


if __name__ == "__main__":
    unittest.main()
