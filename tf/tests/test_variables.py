"""Provider-free Cloudflare variable validation against synthetic inputs only."""

import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCES = {
    "cloudflare-apps": ("workers",),
    "cloudflare-dns": (
        "zones",
        "secret_zones_main",
        "secret_zones_stage",
        "secret_zones_archive",
        "secret_zones_inactive",
    ),
    "cloudflare-platform": ("r2_buckets", "email_routing"),
    "modules/cloudflare": (
        "zones",
        "workers",
        "r2_buckets",
        "email_routing",
        "secret_zones_main",
        "secret_zones_stage",
        "secret_zones_archive",
        "secret_zones_inactive",
    ),
}


def cases(variable):
    """Missing fields, malformed collections and duplicate keys must reject."""
    if variable == "zones" or variable.startswith("secret_zones_"):
        base = {"example.test": {"records": []}}
        lists = {"records": {"key": "apex", "name": "@", "type": "A", "content": "192.0.2.1"}}
    elif variable == "workers":
        base = {"example": {"main_module": "main.js", "modules": [
            {"name": "main.js", "content_file": "synthetic.js", "content_type": "application/javascript"},
        ]}}
        lists = {
            "routes": {"key": "route", "pattern": "example.test/*", "zone_name": "example.test"},
            "custom_domains": {"key": "domain", "hostname": "example.test", "zone_name": "example.test"},
        }
    elif variable == "r2_buckets":
        base = {"example": {}}
        lists = {
            "custom_domains": {"key": "domain", "domain": "example.test", "zone_name": "example.test", "enabled": True},
            "event_notifications": {"key": "notification", "queue_id": "synthetic", "rules": []},
        }
    else:
        base = {"example.test": {}}
        lists = {"rules": {"key": "rule", "matchers": [], "actions": []}}

    yield "empty", {}, True
    yield "base", base, True
    for collection, item in lists.items():
        def value(items):
            result = copy.deepcopy(base)
            next(iter(result.values()))[collection] = items
            return result

        yield f"{collection}_valid", value([item]), True
        yield f"{collection}_duplicates", value([item, item]), False
        yield f"{collection}_distinct", value([item, {**item, "key": "other"}]), True
        yield f"{collection}_null", value(None), False
        yield f"{collection}_wrong_type", value("wrong"), False
        yield f"{collection}_null_item", value([None]), False
        for field in item:
            missing = {key: val for key, val in item.items() if key != field}
            yield f"{collection}_missing_{field}", value([missing]), False

    if variable == "zones" or variable.startswith("secret_zones_"):
        yield "structured_record", {"example.test": {"records": [
            {"key": "srv", "name": "_service._tcp", "type": "SRV", "data": {"port": 443}},
        ]}}, True
    elif variable == "workers":
        yield "assets_only", {"example": {"assets": {"directory": "synthetic"}}}, True
        yield "no_modules_or_assets", {"example": {}}, False
        for broken in (
            {"main_module": "missing.js", "modules": []},
            {"main_module": "other.js", "modules": [
                {"name": "main.js", "content_file": "synthetic", "content_type": "text/javascript"},
            ]},
            {"main_module": "main.js", "modules": [{"name": "main.js"}]},
        ):
            yield "bad_module", {"example": broken}, False


class CloudflareValidationTests(unittest.TestCase):
    def test_variable_contracts(self):
        for source, variables in SOURCES.items():
            text = (ROOT / "tf" / source / "variables.tf").read_text()
            blocks = {match[1]: match[0] for match in re.finditer(
                r'^variable "([^"]+)" \{.*?^\}', text, re.MULTILINE | re.DOTALL
            )}
            for variable in variables:
                with self.subTest(source=source, variable=variable), tempfile.TemporaryDirectory() as tmp:
                    directory = Path(tmp)
                    # Copy declarations only: no providers, resources, real tfvars or state.
                    (directory / "main.tf").write_text(blocks[variable] + "\n")
                    runs = []
                    inputs = list(cases(variable))
                    # nix owns a required, non-null DNS `zones` variable, so
                    # null must fail validation like every other malformed input.
                    inputs.append(("null", None, False))
                    for number, (name, value, valid) in enumerate(inputs):
                        runs.append(
                            f'run "case_{number}_{name}" {{\n'
                            '  command = plan\n'
                            f'  variables {{ {variable} = jsondecode({json.dumps(json.dumps(value))}) }}\n'
                            + ("" if valid else f'  expect_failures = [var.{variable}]\n')
                            + '}\n'
                        )
                    (directory / "validation.tftest.hcl").write_text("\n".join(runs))
                    config = directory / "empty.tfrc"
                    config.touch()
                    environment = {
                        "PATH": os.environ["PATH"], "HOME": tmp,
                        "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "LC_ALL": "C",
                        "TF_CLI_CONFIG_FILE": str(config), "TF_IN_AUTOMATION": "1",
                        "CHECKPOINT_DISABLE": "1",
                    }
                    for args in (("init", "-backend=false", "-input=false"), ("test",)):
                        result = subprocess.run(
                            ["tofu", *args, "-no-color"], cwd=directory, env=environment,
                            text=True, capture_output=True, timeout=60, check=False,
                        )
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(f"{len(runs)} passed, 0 failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
