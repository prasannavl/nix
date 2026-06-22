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
            parse_args generate --host child-1 --stack abird --system incus --incus-host parent --incus-project lab --incus-ipv4 10.10.30.44
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
            parse_args generate --host '-bad'
            validate_common
            """,
            check=False,
        )
        self.assertNotEqual(0, bad_host.returncode)
        self.assertIn("--host must start and end", bad_host.stderr)

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


if __name__ == "__main__":
    unittest.main()
