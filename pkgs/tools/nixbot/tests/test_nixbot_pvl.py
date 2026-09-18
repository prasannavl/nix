"""Pvl's named-topology nixbot ordering test.

Repository identity content for the shared nixbot test area (see
`.agents/docs/design-patterns/shared-test-areas.md`): the shared test_nixbot.py
carries only generic, host-neutral coverage, and named-topology variants belong
to the owning repository as a repo-only sibling module. The shared unittest
discovery in pkgs/tools/nixbot/tests/default.nix picks this file up
automatically; repositories without this file simply run the shared tests.
"""

import json
import unittest

from test_nixbot import NixbotScriptMixin


class PvlTopologyOrderingTest(NixbotScriptMixin, unittest.TestCase):
    def test_control_plane_ordering_matches_pvl_topology(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_HOSTS_JSON='{
              "pvl-a1": {},
              "pvl-l5": {},
              "pvl-x2": {},
              "pvl-vlab": {"parent":"pvl-x2"},
              "pvl-vlab-1": {"parent":"pvl-x2"},
              "pvl-vk": {"parent":"pvl-vlab"},
              "pvl-vk-1": {"parent":"pvl-vlab-1"}
            }'
            NIXBOT_CONTROL_PLANE_HOSTS_JSON='["pvl-x2"]'
            selected='[
              "pvl-a1","pvl-l5","pvl-x2","pvl-vlab",
              "pvl-vlab-1","pvl-vk","pvl-vk-1"
            ]'
            ordered="$(order_selected_hosts_json "$selected" "$selected")"
            printf '%s\n' "$ordered"
            selected_host_levels_json "$ordered" | jq -c .

            CONTROL_PLANE_FIRST=1
            ordered="$(order_selected_hosts_json "$selected" "$selected")"
            printf '%s\n' "$ordered"
            selected_host_levels_json "$ordered" | jq -c .
            """
        )

        default_order, default_levels, first_order, first_levels = [
            json.loads(line) for line in result.stdout.splitlines()
        ]
        self.assertLess(default_order.index("pvl-l5"), default_order.index("pvl-x2"))
        self.assertEqual(
            [
                ["pvl-a1", "pvl-l5"],
                ["pvl-x2"],
                ["pvl-vlab", "pvl-vlab-1"],
                ["pvl-vk", "pvl-vk-1"],
            ],
            default_levels,
        )
        self.assertEqual("pvl-x2", first_order[0])
        self.assertEqual(
            [
                ["pvl-x2"],
                ["pvl-a1", "pvl-l5", "pvl-vlab", "pvl-vlab-1"],
                ["pvl-vk", "pvl-vk-1"],
            ],
            first_levels,
        )
