import importlib.util
import tempfile
import unittest
from pathlib import Path


class QuadletCompilerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)
        compiler = cls.repo_root / "lib/podman-compose/quadlet-compiler.py"
        spec = importlib.util.spec_from_file_location("quadlet_compiler", compiler)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"unable to load {compiler}")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_nested_interpolation_is_recursive_and_lazy(self):
        interpolate = self.module.interpolate
        self.assertEqual(
            "fallback",
            interpolate("${OUTER:-${INNER:-fallback}}", {}, "test"),
        )
        self.assertEqual(
            "selected",
            interpolate(
                "${OUTER:-${MISSING:?must not be evaluated}}",
                {"OUTER": "selected"},
                "test",
            ),
        )
        self.assertEqual(
            "prefix-alternate-suffix",
            interpolate(
                "prefix-${VALUE:+${OTHER}}-suffix",
                {"VALUE": "set", "OTHER": "alternate"},
                "test",
            ),
        )
        self.assertEqual("$HOME", interpolate("$$HOME", {}, "test"))
        self.assertEqual("$$HOME", interpolate("$$$$HOME", {}, "test"))
        self.assertEqual(
            "${INNER}", interpolate("${OUTER:-$${INNER}}", {}, "test")
        )

    def test_invalid_interpolation_fails_closed(self):
        with self.assertRaisesRegex(self.module.CompileError, "unterminated"):
            self.module.interpolate("${VALUE", {}, "test")
        with self.assertRaisesRegex(self.module.CompileError, "unsupported"):
            self.module.interpolate("${VALUE/foo/bar}", {"VALUE": "x"}, "test")
        with self.assertRaisesRegex(self.module.CompileError, "required.*VALUE"):
            self.module.interpolate("${VALUE:?missing}", {}, "test")

    def test_interpolation_distinguishes_unset_from_empty(self):
        interpolate = self.module.interpolate
        env = {"EMPTY": "", "SET": "value"}
        self.assertEqual("", interpolate("${EMPTY-default}", env, "test"))
        self.assertEqual("default", interpolate("${EMPTY:-default}", env, "test"))
        self.assertEqual("default", interpolate("${UNSET-default}", env, "test"))
        self.assertEqual("alternate", interpolate("${EMPTY+alternate}", env, "test"))
        self.assertEqual("", interpolate("${EMPTY:+alternate}", env, "test"))
        self.assertEqual("", interpolate("${UNSET+alternate}", env, "test"))
        self.assertEqual("value", interpolate("${SET:?missing}", env, "test"))
        self.assertEqual("", interpolate("${EMPTY?missing}", env, "test"))

    def test_compose_interpolates_values_but_not_mapping_keys(self):
        with tempfile.TemporaryDirectory(
            prefix="quadlet-compiler-test.", dir=self.tmp_root
        ) as tmp:
            compose = Path(tmp) / "compose.yml"
            compose.write_text(
                """services:
  ${SERVICE_NAME}:
    image: ${REGISTRY:-docker.io}/library/busybox:${TAG:-latest}
""",
                encoding="utf-8",
            )
            model = self.module.load_compose(
                [str(compose)],
                {"SERVICE_NAME": "changed", "TAG": "stable"},
            )
        self.assertIn("${SERVICE_NAME}", model["services"])
        self.assertEqual(
            "docker.io/library/busybox:stable",
            model["services"]["${SERVICE_NAME}"]["image"],
        )

    def test_dotenv_implements_compose_quoting_comments_and_expansion(self):
        with tempfile.TemporaryDirectory(
            prefix="quadlet-dotenv-test.", dir=self.tmp_root
        ) as tmp:
            dotenv = Path(tmp) / ".env"
            dotenv.write_text(
                """BASE=registry.example
TAG=${CHANNEL:-stable}
COMMENTED=value # ignored
HASH=value#literal
DOUBLE="${BASE}\\t${TAG}"
SINGLE='${BASE}'
MULTILINE='first
second'
EMPTY=
UNSET
""",
                encoding="utf-8",
            )
            values = self.module.load_dotenv(str(dotenv))
        self.assertEqual("registry.example", values["BASE"])
        self.assertEqual("stable", values["TAG"])
        self.assertEqual("value", values["COMMENTED"])
        self.assertEqual("value#literal", values["HASH"])
        self.assertEqual("registry.example\tstable", values["DOUBLE"])
        self.assertEqual("${BASE}", values["SINGLE"])
        self.assertEqual("first\nsecond", values["MULTILINE"])
        self.assertEqual("", values["EMPTY"])
        self.assertNotIn("UNSET", values)

    def test_unset_environment_entries_are_inherited_or_omitted(self):
        entries = self.module.environment_entries(
            "app",
            {"FROM_PROJECT": None, "MISSING": None, "EMPTY": ""},
            {"FROM_PROJECT": "resolved"},
        )
        self.assertEqual(
            [
                ("Environment", '"FROM_PROJECT=resolved"', True),
                ("Environment", '"EMPTY="', True),
            ],
            entries,
        )
        list_entries = self.module.environment_entries(
            "app", ["FROM_PROJECT", "MISSING", "EMPTY="], {"FROM_PROJECT": "resolved"}
        )
        self.assertEqual(entries, list_entries)

    def test_runtime_gate_is_strict_and_runtime_scoped(self):
        entries = self.module.runtime_gate_entries(
            {
                "runtimeGate": {
                    "readinessUnit": "abird-host-agent-holds-ready.service",
                    "conditionPathExists": [
                        "|!/var/lib/abird-host-agent/holds/service.json",
                        "|/var/lib/abird-host-agent/activation-authorizations/service.json",
                    ],
                }
            }
        )
        self.assertEqual(
            [
                ("Requires", "abird-host-agent-holds-ready.service", False),
                ("After", "abird-host-agent-holds-ready.service", False),
                (
                    "ConditionPathExists",
                    "|!/var/lib/abird-host-agent/holds/service.json",
                    False,
                ),
                (
                    "ConditionPathExists",
                    "|/var/lib/abird-host-agent/activation-authorizations/service.json",
                    False,
                ),
            ],
            entries,
        )
        with self.assertRaisesRegex(self.module.CompileError, "absolute paths"):
            self.module.runtime_gate_entries(
                {
                    "runtimeGate": {
                        "readinessUnit": "abird-host-agent-holds-ready.service",
                        "conditionPathExists": ["relative/path"],
                    }
                }
            )
        with self.assertRaisesRegex(self.module.CompileError, "valid service unit"):
            self.module.runtime_gate_entries(
                {
                    "runtimeGate": {
                        "readinessUnit": "/tmp/holds-ready.service",
                        "conditionPathExists": ["!/var/lib/holds/service.json"],
                    }
                }
            )


if __name__ == "__main__":
    unittest.main()
