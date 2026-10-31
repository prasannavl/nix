"""Control-plane ordering across independent nested parent branches."""

import json
import unittest

from test_nixbot import NixbotScriptMixin


class NestedControlPlaneOrderingTest(NixbotScriptMixin, unittest.TestCase):
    def test_control_plane_ordering_across_nested_parent_branches(self):
        result = self.run_script(
            """
            init_vars
            NIXBOT_HOSTS_JSON='{
              "worker-a": {},
              "worker-b": {},
              "controller": {},
              "parent-a": {"parent":"controller"},
              "parent-b": {"parent":"controller"},
              "leaf-a": {"parent":"parent-a"},
              "leaf-b": {"parent":"parent-b"}
            }'
            NIXBOT_CONTROL_PLANE_HOSTS_JSON='["controller"]'
            selected='[
              "worker-a","worker-b","controller","parent-a",
              "parent-b","leaf-a","leaf-b"
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
        self.assertLess(
            default_order.index("worker-b"), default_order.index("controller")
        )
        self.assertEqual(
            [
                ["worker-a", "worker-b"],
                ["controller"],
                ["parent-a", "parent-b"],
                ["leaf-a", "leaf-b"],
            ],
            default_levels,
        )
        self.assertEqual("controller", first_order[0])
        self.assertEqual(
            [
                ["controller"],
                ["worker-a", "worker-b", "parent-a", "parent-b"],
                ["leaf-a", "leaf-b"],
            ],
            first_levels,
        )
