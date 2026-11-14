import base64
import json
import os
import shlex
import shutil
import subprocess
import unittest

from test_nixbot import NixbotScriptMixin


class BuildStrategyTests(NixbotScriptMixin, unittest.TestCase):
    def contract(self):
        path = (
            self.repo_root
            / "pkgs/tools/abird-host-manager/tests/fixtures/build-strategies.json"
        )
        return json.loads(path.read_text(encoding="utf-8"))

    def test_shared_bash_and_native_strategy_contract(self):
        contract = self.contract()
        for case in contract["cases"]:
            with self.subTest(case=case["name"]):
                result = self.run_script(
                    f"""
                    init_vars
                    ACTION=build
                    normalize_host_action
                    parse_args {shlex.join(case["args"])}
                    forwarded=()
                    append_build_strategy_args forwarded
                    effective="$(resolve_build_strategy "${{BUILD_STRATEGY_REQUEST}}" 2>"${{TEST_ERROR}}")" || true
                    error="$(<"${{TEST_ERROR}}")"
                    jq -cn --arg requested "${{BUILD_STRATEGY_REQUEST}}" \
                      --arg forwarded "${{forwarded[1]:-}}" \
                      --arg effective "${{effective}}" --arg error "${{error}}" \
                      '{{requested:$requested, forwarded:($forwarded|select(. != "") // null), effective:($effective|select(. != "") // null), error:$error}}'
                    """,
                    env={
                        "NIXBOT_STRATEGY": case["environment"] or "",
                        "TEST_ERROR": str(self.work_dir / "strategy-error"),
                    },
                    check=False,
                )
                if case.get("parse_error"):
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = json.loads(result.stdout)
                for field in ("requested", "forwarded", "effective"):
                    self.assertEqual(actual[field], case[field])
                self.assertEqual(actual["error"], "")
        constant = self.run_script('printf %s "${NIXBOT_AGENT_CI_DEFERRED}"')
        self.assertEqual(constant.stdout, contract["agent_ci_deferred"])

    def test_agent_delegates_to_the_shared_backend_before_bash_effects(self):
        marker = self.work_dir / "effect"
        fake_bin = self.work_dir / "fake-bin"
        fake_bin.mkdir()
        manager = fake_bin / "abird-host-manager"
        manager.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n', encoding="utf-8")
        manager.chmod(0o755)
        stubs = """
            effect() { touch "${TEST_EFFECT}"; return 97; }
            ensure_runtime_ready() { :; }
            capture_initial_tty_state() { :; }
            cleanup_trap() { :; }
            cleanup_stale_runtime_dirs() { effect; }
            prepare_repo_worktree() { effect; }
            prepare_run_context() { effect; }
            run_deploy_request_action() { effect; }
            run_ci_trigger() { effect; }
            """
        environment = {
            "NIXBOT_STRATEGY": "",
            "TEST_EFFECT": str(marker),
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
        }
        for action in ("run", "deploy", "build", "dev-build"):
            for dry in (False, True):
                flags = ["--strategy=agent"] + (["--dry"] if dry else [])
                with self.subTest(action=action, dry=dry, entry="main"):
                    result = self.run_script(
                        stubs + f"main {action} {shlex.join(flags)}",
                        env=environment,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), ["fleet", action, *flags])
                    self.assertFalse(marker.exists())
                for entry in ("run_requested_action", "run_build_phase"):
                    with self.subTest(action=action, dry=dry, entry=entry):
                        result = self.run_script(
                            stubs
                            + f"init_vars; ACTION={action}; normalize_host_action; "
                            f"parse_args {shlex.join(flags)}; {entry}",
                            env=environment,
                            check=False,
                        )
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("runs only through its own backend", result.stderr)
                        self.assertFalse(marker.exists())
        # The shared Rust frontend owns ordinary CI forwarding too.
        result = self.run_script(
            stubs + "main build --strategy=agent --ci-trigger --sha abcdef0",
            env=environment,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["fleet", "build", "--strategy=agent", "--ci-trigger", "--sha", "abcdef0"])
        self.assertFalse(marker.exists())

    def test_build_phase_dispatches_only_the_selected_implemented_strategy(self):
        for requested in ("auto", "nix"):
            result = self.run_script(
                """
                init_vars
                run_nix_build_phase() { printf 'legacy:<%s>\\n' "$@"; }
                run_build_phase 'exact argument' next
                """,
                env={"NIXBOT_STRATEGY": requested},
            )
            self.assertEqual(result.stdout, "legacy:<exact argument>\nlegacy:<next>\n")
        unsupported = self.run_script(
            """
            resolve_build_strategy() { printf 'future\\n'; }
            run_nix_build_phase() { echo UNEXPECTED_LEGACY; }
            run_build_phase
            """,
            check=False,
        )
        self.assertNotEqual(unsupported.returncode, 0)
        self.assertIn("Unsupported resolved build strategy: future", unsupported.stderr)
        self.assertNotIn("UNEXPECTED_LEGACY", unsupported.stdout)

    def test_forced_command_owned_delegates_before_bash_workflow(self):
        fake_bin = self.work_dir / "forced-bin"
        fake_bin.mkdir()
        manager = fake_bin / "abird-host-manager"
        manager.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n', encoding="utf-8")
        manager.chmod(0o755)
        payload = base64.b64encode(b"build\0--strategy=agent\0--dry\0").decode()
        result = self.run_script(
            """
            ensure_runtime_ready() { :; }
            capture_initial_tty_state() { :; }
            cleanup_trap() { :; }
            cleanup_stale_runtime_dirs() { echo UNEXPECTED_EFFECT; return 97; }
            main
            """,
            env={"SSH_ORIGINAL_COMMAND": "__nixbot_argv64 " + payload, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["fleet", "build", "--strategy=agent", "--dry"])
        self.assertNotIn("UNEXPECTED_EFFECT", result.stdout)

    def test_ci_forwards_explicit_intent_without_local_availability_resolution(self):
        config = self.work_dir / "hosts.nix"
        config.write_text("{}\n", encoding="utf-8")
        for environment, args, expected in (
            ("", [], None),
            ("", ["--strategy=auto"], "auto"),
            ("", ["--strategy", "agent"], "owned"),
            ("nix", [], "legacy"),
            ("agent", ["--strategy=nix"], "legacy"),
            ("agent", ["--strategy=auto"], "auto"),
        ):
            with self.subTest(environment=environment, args=args):
                result = self.run_script(
                    f"""
                    init_vars
                    ACTION=build
                    normalize_host_action
                    parse_args --ci-trigger --sha abcdef0 --hosts app {shlex.join(args)}
                    NIXBOT_CONFIG_PATH="${{TEST_CONFIG}}"
                    CI_TRIGGER_HOST=controller
                    CI_TRIGGER_USER=nixbot
                    load_deploy_config_bundle() {{
                      jq -cn --argjson config '{{"hosts":{{"app":{{}},"controller":{{"target":"ci.example"}}}},"config":{{}}}}' \
                        '{{config:$config,base:$config,override:{{}},overrideActive:0}}'
                    }}
                    configure_ci_trigger_ssh_opts() {{ CI_TRIGGER_SSH_OPTS=(); }}
                    ssh() {{ printf '%s\\n' "${{!#}}"; }}
                    run_ci_trigger
                    """,
                    env={"NIXBOT_STRATEGY": environment, "TEST_CONFIG": str(config)},
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                remote = next(
                    line for line in result.stdout.splitlines() if line.startswith("__nixbot_argv64 ")
                )
                argv = base64.b64decode(remote.split()[1]).decode().split("\0")[:-1]
                if expected is None:
                    self.assertNotIn("--strategy", argv)
                else:
                    self.assertEqual(argv[argv.index("--strategy") + 1], expected)
                self.assertIn("--no-override", argv)
                self.assertNotIn("--route", argv)

    def test_reexec_freezes_explicit_environment_and_cli_choice(self):
        child = self.work_dir / "child.sh"
        child.write_text("printf '%s\\0' \"$@\"\n", encoding="utf-8")
        for environment, args, expected in (
            ("", [], None),
            ("nix", [], "legacy"),
            ("agent", ["--strategy=auto"], "auto"),
        ):
            with self.subTest(environment=environment, args=args):
                result = self.run_script(
                    f"""
                    init_vars
                    ACTION=build
                    normalize_host_action
                    parse_args {shlex.join(args)}
                    REEXEC_FROM_REPO=1
                    CONFIG_OVERRIDE_PINNED=1
                    CONFIG_OVERRIDE_PINNED_PATH=''
                    repo_worktree_script_path() {{ printf '%s\\n' "${{TEST_CHILD}}"; }}
                    reexec_repo_script_if_needed build {shlex.join(args)}
                    """,
                    env={"NIXBOT_STRATEGY": environment, "TEST_CHILD": str(child)},
                )
                argv = result.stdout.split("\0")[:-1]
                self.assertIn("--no-override", argv)
                if expected is None:
                    self.assertNotIn("--strategy", argv)
                else:
                    self.assertEqual(argv[-2:], ["--strategy", expected])

    def test_completion_and_nonbuild_action_scope(self):
        completion = self.repo_root / "pkgs/tools/nixbot/nixbot.bash"
        for words, expected in (
            (["nixbot", "build", "--strategy", ""], ["auto", "nix", "agent"]),
            (["nixbot", "build", "--strategy", "=", "ag"], ["agent"]),
            (["nixbot", "build", "--strategy=ag"], ["--strategy=agent"]),
        ):
            result = self.run_script(
                f"""
                source {shlex.quote(str(completion))}
                _nixbot_tf_projects() {{ :; }}
                COMP_WORDS=({shlex.join(words)})
                COMP_CWORD={len(words) - 1}
                _nixbot
                printf '%s\\n' "${{COMPREPLY[@]}}"
                """
            )
            self.assertEqual(result.stdout.splitlines(), expected)
        self.run_script(
            """
            for action in help version deps check-deps repo-sync list-hosts list-groups tf tf-dns tf-platform tf-apps tf/custom clean check-bootstrap tofu; do
              if action_uses_build_strategy "${action}"; then exit 97; fi
            done
            """
        )


class FrontendBootstrapTests(NixbotScriptMixin, unittest.TestCase):
    """Execute the real entrypoint/bootstrap, with no installed services or Nix."""

    def setUp(self):
        super().setUp()
        self.bash = shutil.which("bash")
        self.fake_bin = self.work_dir / "bin"
        self.fake_bin.mkdir()
        self.records = self.work_dir / "records"
        self.records.mkdir()
        # Only local, read-only parser/initialization tools. In particular, no
        # real manager, Nix, SSH, host discovery, or cleanup commands can run.
        for command in (
            "awk", "base64", "cat", "date", "dirname", "nproc", "paste", "ps", "readlink", "tr",
        ):
            (self.fake_bin / command).symlink_to(shutil.which(command))
        for command in ("hostname", "ip", "rmdir"):
            self.write_executable(command, "exit 0\n")
        self.write_executable("git", 'printf "%s\\n" "$TEST_REPO_ROOT"\n')
        for command, status in (("nix", 73), ("abird-host-manager", 23)):
            body = (
                f'[[ ! -e "$TEST_RECORDS/{command}" ]] || exit 98\n'
                f'printf "%s\\0" "$@" > "$TEST_RECORDS/{command}"\n'
                f'printf "%s\\0" "${{NIXBOT_STRATEGY-}}" '
                f'"${{NIXBOT_IN_NIX_SHELL-unset}}" > "$TEST_RECORDS/{command}-env"\n'
                f'printf "%s" "${{SSH_ORIGINAL_COMMAND-}}" > "$TEST_RECORDS/{command}-ssh"\n'
            )
            if command == "nix":
                body += """
if [[ "${TEST_BOOTSTRAP_REEXEC:-0}" = 1 ]]; then
    while [[ "$1" != -c ]]; do shift; done
    shift
    printf '%s\\0' "$@" > "$TEST_RECORDS/reexec"
    exec "$@"
fi
"""
            self.write_executable(command, body + f"exit {status}\n")

    def write_executable(self, name, body):
        path = self.fake_bin / name
        path.write_text(f"#!{self.bash}\nset -Eeuo pipefail\n{body}", encoding="utf-8")
        path.chmod(0o755)

    def run_frontend(self, args, *, env=None):
        for record in self.records.iterdir():
            record.unlink()
        # Do not inherit workstation strategy, tokens, runtime paths, shell
        # functions, or the packaged wrapper's NIXBOT_IN_NIX_SHELL guard.
        environment = {
            "PATH": str(self.fake_bin),
            "HOME": str(self.work_dir),
            "TMPDIR": str(self.work_dir),
            "LC_ALL": "C",
            "TEST_RECORDS": str(self.records),
            "TEST_REPO_ROOT": str(self.repo_root),
        }
        environment.update(env or {})
        return subprocess.run(
            [self.bash, str(self.script), *args],
            cwd=self.work_dir,
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def recorded_args(self, command):
        return (self.records / command).read_bytes().decode().split("\0")[:-1]

    def assert_delegated(self, result, args, strategy="", shell_flag="unset"):
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.recorded_args("abird-host-manager"), ["fleet", *args])
        self.assertEqual(
            self.recorded_args("abird-host-manager-env"), [strategy, shell_flag]
        )
        self.assertFalse((self.records / "nix").exists())

    def test_direct_agent_selection_precedes_real_runtime_bootstrap(self):
        for action in ("run", "deploy", "build", "dev-build"):
            for dry in ([], ["--dry"]):
                for strategy, flags in (
                    ("", ["--strategy=agent"]),
                    ("", ["--strategy", "owned"]),
                    ("agent", []),
                    ("owned", []),
                    ("nix", ["--strategy", "agent"]),
                ):
                    with self.subTest(
                        action=action, dry=dry, strategy=strategy, flags=flags
                    ):
                        args = [
                            action, *flags, *dry, "--config", "a path/'quoted'\nconfig.nix",
                        ]
                        result = self.run_frontend(args, env={"NIXBOT_STRATEGY": strategy})
                        self.assert_delegated(result, args, strategy)

    def test_agent_thin_ci_delegates_without_local_runtime_or_profile(self):
        for flags, env in (
            (["--strategy=agent", "--ci-trigger"], {}),
            ([], {"NIXBOT_STRATEGY": "owned", "NIXBOT_CI_TRIGGER": "1"}),
        ):
            with self.subTest(flags=flags, env=env):
                args = ["build", *flags, "--sha", "abcdef0", "--dry", "--hosts", "app"]
                result = self.run_frontend(args, env=env)
                self.assert_delegated(result, args, env.get("NIXBOT_STRATEGY", ""))

    def test_agent_hydrated_argv_is_forwarded_without_reconstruction(self):
        args = [
            "deploy", "--strategy", "owned", "--dry", "--config", "a path/'quoted'\nconfig.nix",
        ]
        payload = base64.b64encode("\0".join([*args, ""]).encode()).decode()
        for incoming, env in (
            (["__nixbot_argv64", payload], {}),
            ([], {"SSH_ORIGINAL_COMMAND": "__nixbot_argv64 " + payload}),
        ):
            with self.subTest(incoming=incoming, env=env):
                self.assert_delegated(self.run_frontend(incoming, env=env), args)
        simple_args = ["build", "--strategy=owned", "--dry"]
        result = self.run_frontend(
            [], env={"SSH_ORIGINAL_COMMAND": "-- /synthetic/nixbot " + " ".join(simple_args)}
        )
        self.assert_delegated(result, simple_args)

    def test_missing_manager_rejects_agent_without_nix_fallback(self):
        (self.fake_bin / "abird-host-manager").unlink()
        result = self.run_frontend(["build", "--strategy=agent", "--dry"])
        self.assertEqual(result.returncode, 127, result.stderr)
        self.assertIn("abird-host-manager: not found", result.stderr)
        self.assertFalse((self.records / "nix").exists())

    def test_packaged_agent_skips_ordinary_runtime_tool_check(self):
        args = ["build", "--strategy=agent", "--dry"]
        result = self.run_frontend(args, env={"NIXBOT_IN_NIX_SHELL": "1"})
        self.assert_delegated(result, args, shell_flag="1")

    def test_auto_and_nix_keep_real_runtime_shell_bootstrap(self):
        for strategy, flags in (
            ("", []),
            ("", ["--strategy=auto"]),
            ("", ["--strategy=nix"]),
            ("", ["--strategy", "legacy"]),
            ("auto", []),
            ("nix", []),
            ("legacy", []),
            ("agent", ["--strategy=auto"]),
            ("owned", ["--strategy=nix"]),
        ):
            with self.subTest(strategy=strategy, flags=flags):
                args = ["build", *flags, "--dry", "--config", "a config.nix"]
                result = self.run_frontend(args, env={"NIXBOT_STRATEGY": strategy})
                self.assertEqual(result.returncode, 73, result.stderr)
                actual = self.recorded_args("nix")
                self.assertEqual(actual[:6], [
                    "--quiet", "--no-warn-dirty", "shell", "--inputs-from",
                    str(self.repo_root), "nixpkgs#age",
                ])
                self.assertIn("nixpkgs#nix", actual)
                self.assertEqual(actual[actual.index("-c"):], [
                    "-c", "env", "NIXBOT_IN_NIX_SHELL=1", "NIXBOT_CONFIG_OVERRIDE_PATH=",
                    "bash", str(self.script), *args,
                ])
                self.assertEqual(self.recorded_args("nix-env"), [strategy, "unset"])
                self.assertFalse((self.records / "abird-host-manager").exists())

    def use_sparse_path(self):
        # Keep only the inherited bootstrap prerequisites (date, dirname,
        # base64 for encoded argv), not runtime/parser utilities or help's cat.
        for command in ("awk", "paste", "tr", "cat", "nproc", "ps", "readlink"):
            (self.fake_bin / command).unlink()
        for command in ("bash", "env"):
            (self.fake_bin / command).symlink_to(shutil.which(command))

    def selector_cases(self):
        return (
            (["--group", "prod"], {}),
            (["--group=prod,prod", "--group", "canary"], {}),
            (["--require-hosts", "app"], {}),
            (["--require-hosts=app,app", "--require-hosts", "other"], {}),
            (["--host", "app", "--nix-config", "app"], {}),
            (["--host=app", "--nix-config=app-alt"], {}),
            (["--hosts", "app,app,-old", "--nix-config", "app-alt"], {}),
            (["--hosts=app", "--nix-config=app"], {}),
            (["--hosts", "app*,all,-old"], {}),
            (["--group", "prod", "--hosts", "app", "--require-hosts", "app"], {}),
            ([], {"NIXBOT_HOSTS": "app,app,-old", "NIXBOT_NIX_CONFIG": "app-alt",
                  "NIXBOT_GROUPS": "prod"}),
            (["--group", "prod", "--ci-trigger", "--sha", "abcdef0"], {}),
            (["--group=prod", "--sha=abcdef0"], {"NIXBOT_CI_TRIGGER": "1"}),
        )

    def test_awk_absent_reviewer_selector_matrix_reexecutes(self):
        (self.fake_bin / "awk").unlink()
        for command in ("bash", "env"):
            (self.fake_bin / command).symlink_to(shutil.which(command))
        cases = self.selector_cases()
        for flags in ([], ["--strategy=auto"], ["--strategy=nix"], ["--strategy=legacy"]):
            for selectors, _ in (cases[0], cases[2], cases[4]):
                with self.subTest(flags=flags, selectors=selectors):
                    args = ["build", *flags, *selectors, "--dry"]
                    result = self.run_frontend(args, env={"TEST_BOOTSTRAP_REEXEC": "1"})
                    self.assert_bootstrapped_and_reexecuted(result, args)

    def test_sparse_selectors_bootstrap_and_reexec_or_delegate_agent(self):
        self.use_sparse_path()
        for strategy, flags, agent in (
            ("", [], False),
            ("", ["--strategy=auto"], False),
            ("", ["--strategy=nix"], False),
            ("", ["--strategy", "legacy"], False),
            ("auto", [], False),
            ("nix", [], False),
            ("legacy", [], False),
            ("agent", ["--strategy=auto"], False),
            ("owned", ["--strategy=nix"], False),
            ("", ["--strategy=agent"], True),
            ("", ["--strategy", "owned"], True),
            ("agent", [], True),
            ("owned", [], True),
            ("nix", ["--strategy=agent"], True),
        ):
            for selectors, selector_env in self.selector_cases():
                with self.subTest(strategy=strategy, flags=flags, selectors=selectors,
                                  selector_env=selector_env):
                    args = ["build", *flags, *selectors, "--dry"]
                    result = self.run_frontend(args, env={
                        **selector_env, "NIXBOT_STRATEGY": strategy,
                        "TEST_BOOTSTRAP_REEXEC": "1",
                    })
                    if agent:
                        self.assert_delegated(result, args, strategy)
                        self.assertFalse((self.records / "reexec").exists())
                    else:
                        self.assert_bootstrapped_and_reexecuted(result, args)

    def assert_bootstrapped_and_reexecuted(self, result, args):
        # A real second Bash process reaches the real tool check, then stops
        # safely: age is intentionally absent, so no workflow can run.
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Required command not found: age", result.stderr)
        self.assertIn("nixpkgs#gawk", self.recorded_args("nix"))
        self.assertEqual(self.recorded_args("nix-env")[1], "unset")
        self.assertEqual(self.recorded_args("reexec"), [
            "env", "NIXBOT_IN_NIX_SHELL=1", "NIXBOT_CONFIG_OVERRIDE_PATH=",
            "bash", str(self.script), *args,
        ])
        self.assertFalse((self.records / "abird-host-manager").exists())

    def test_sparse_hydrated_selectors_and_help_version(self):
        self.use_sparse_path()
        for strategy in ("auto", "nix", "legacy", "agent", "owned"):
            args = ["build", f"--strategy={strategy}", "--group=prod", "--dry"]
            payload = base64.b64encode("\0".join([*args, ""]).encode()).decode()
            for incoming, envelope in (
                (["__nixbot_argv64", payload], {}),
                ([], {"SSH_ORIGINAL_COMMAND": "__nixbot_argv64 " + payload}),
                ([], {"SSH_ORIGINAL_COMMAND": "nixbot " + " ".join(args)}),
            ):
                with self.subTest(strategy=strategy, incoming=incoming, envelope=envelope):
                    result = self.run_frontend(incoming, env={
                        **envelope, "TEST_BOOTSTRAP_REEXEC": "1",
                    })
                    if strategy in ("agent", "owned"):
                        self.assert_delegated(result, args)
                    else:
                        self.assert_bootstrapped_and_reexecuted(result, incoming)
                        self.assertEqual(
                            (self.records / "nix-ssh").read_text(encoding="utf-8"),
                            envelope.get("SSH_ORIGINAL_COMMAND", ""),
                        )
        for args, status, expected in (
            ([], 0, "Usage:"),
            (["help"], 0, "Usage:"),
            (["--help"], 0, "Usage:"),
            (["-h"], 0, "Usage:"),
            (["build", "--group", "prod", "--help"], 0, "Usage:"),
            (["deps", "--help"], 0, "Usage:"),
            (["check-deps", "--help"], 0, "Usage:"),
            (["version", "--help"], 0, "Usage:"),
            (["version"], 0, "2026.07.23"),
            # --version is not an alias in the Bash frontend; preserve its error.
            (["--version"], 1, "Unknown subcommand: --version"),
        ):
            with self.subTest(args=args):
                result = self.run_frontend(args)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(expected, result.stdout + result.stderr)
                self.assertFalse((self.records / "nix").exists())
                self.assertFalse((self.records / "abird-host-manager").exists())

    def test_sparse_selector_errors_remain_errors(self):
        self.use_sparse_path()
        for selectors, error in (
            (["--group", " ,\t\n "], "--group cannot be empty"),
            (["--require-hosts", " ,\t\n "], "--require-hosts cannot be empty"),
            (["--host", "app", "--hosts", "app"], "Use either --host or --hosts"),
            (["--host", "all"], "--host requires one exact host"),
            (["--hosts", "app,other", "--nix-config", "app"], "exactly one positive"),
            (["--hosts", "-app", "--nix-config", "app"], "exactly one positive"),
            (["--hosts", "app*", "--nix-config", "app"], "exactly one positive"),
            (["--hosts", "all", "--nix-config", "app"], "exactly one positive"),
            (["--host", "app", "--nix-config", "bad/name"], "valid NixOS configuration"),
        ):
            for strategy in ("nix", "agent"):
                with self.subTest(selectors=selectors, strategy=strategy):
                    result = self.run_frontend(["build", f"--strategy={strategy}", *selectors])
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(error, result.stderr)
                    self.assertFalse((self.records / "nix").exists())
                    self.assertFalse((self.records / "abird-host-manager").exists())

    def test_selector_helpers_preserve_normalization_without_external_tools(self):
        values = (
            "", " ,\n\t", "all", "app app,other\napp", "app*,a?,[ab],-old,app*",
            "01,1,1.0,01", "\tapp\t,app\t,\t", "app\r\nother\v,third\f",
            "'quoted',back\\slash,$(false),[x],-n,-e", "app,é,é", "app\n\n",
        )
        # The previous implementation is the byte/ordering oracle. Only that
        # oracle gets runtime tools; the actual helpers run with an empty PATH.
        self.run_script(
            f"""
            original_path="$PATH"
            for raw in {shlex.join(values)}; do
                PATH="$original_path"
                expected="$(printf '%s' "$raw" | tr ', ' '\\n' | awk 'NF && !seen[$0]++')"
                expected_csv="$(printf '%s' "$raw" | tr ', ' '\\n' | awk 'NF && !seen[$0]++' | paste -sd, -)"
                PATH="${{TEST_EMPTY_PATH}}"
                [[ "$(emit_normalized_hosts "$raw")" = "$expected" ]]
                [[ "$(normalize_hosts_input "$raw")" = "$expected_csv" ]]
                [[ "$(normalize_groups_input "$raw")" = "$expected_csv" ]]
            done
            """,
            env={"TEST_EMPTY_PATH": str(self.work_dir / "no-tools")},
        )

    def test_managed_override_rejection_survives_prebootstrap_parsing(self):
        # --no-override clears the exported path during parsing. Reject the
        # original explicit intent before a shell re-exec could forget it.
        for strategy in ("auto", "nix"):
            for variable in ("NIXBOT_CONFIG_OVERRIDE_PATH", "ABIRD_HOST_MANAGER_CONFIG_OVERRIDE"):
                with self.subTest(strategy=strategy, variable=variable):
                    result = self.run_frontend(
                        ["build", f"--strategy={strategy}", "--no-override"],
                        env={
                            "NIXBOT_EXECUTOR_KIND": "managed",
                            variable: "synthetic.override.nix",
                        },
                    )
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(
                        "config overrides are allowed only for direct developer execution",
                        result.stderr,
                    )
                    self.assertFalse((self.records / "nix").exists())
                    self.assertFalse((self.records / "abird-host-manager").exists())

    def test_forced_auto_keeps_bootstrap_and_original_ssh_envelope(self):
        original = "__nixbot_argv64 " + base64.b64encode(
            b"build\0--strategy=auto\0--dry\0"
        ).decode()
        result = self.run_frontend([], env={"SSH_ORIGINAL_COMMAND": original})
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual((self.records / "nix-ssh").read_text(encoding="utf-8"), original)
        actual = self.recorded_args("nix")
        self.assertEqual(actual[:4], ["--quiet", "--no-warn-dirty", "shell", "nixpkgs#age"])
        self.assertNotIn("--inputs-from", actual)
        self.assertEqual(actual[actual.index("-c"):], [
            "-c", "env", "NIXBOT_IN_NIX_SHELL=1", "NIXBOT_CONFIG_OVERRIDE_PATH=",
            "bash", str(self.script),
        ])
        self.assertFalse((self.records / "abird-host-manager").exists())

    def test_nonbuild_actions_do_not_delegate_environment_agent_strategy(self):
        for action in ("help", "version", "deps", "tf"):
            with self.subTest(action=action):
                result = self.run_frontend([action], env={"NIXBOT_STRATEGY": "agent"})
                bootstraps = action in ("deps", "tf")
                self.assertEqual(result.returncode, 73 if bootstraps else 0, result.stderr)
                self.assertEqual((self.records / "nix").exists(), bootstraps)
                self.assertFalse((self.records / "abird-host-manager").exists())
