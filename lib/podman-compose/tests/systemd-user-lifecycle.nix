{pkgs, ...}: let
  uid = 1234;
  verifyScript = pkgs.writeShellScript "systemd-user-lifecycle-verify" ''
    set -eu

    runtime_dir="$1"
    service_name="$2"
    counter_file="$runtime_dir/$service_name-verify-count"
    failure_file="$runtime_dir/$service_name-verify-fail"
    count=0

    if [ -r "$counter_file" ]; then
      count="$(<"$counter_file")"
    fi
    printf '%s\n' "$((count + 1))" >"$counter_file"

    [ ! -e "$failure_file" ]
  '';
in {
  name = "podman-compose-systemd-user-lifecycle";

  nodes.machine = {...}: {
    system.stateVersion = "26.05";

    users = {
      manageLingering = true;
      users.tester = {
        isNormalUser = true;
        uid = uid;
        linger = true;
      };
    };

    systemd.user = {
      services = {
        test-alpha = {
          unitConfig = {
            ConditionUser = "tester";
            PartOf = ["test-managed.target"];
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
        };
        test-beta = {
          unitConfig = {
            ConditionUser = "tester";
            PartOf = ["test-managed.target"];
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
        };
        test-alpha-verify = {
          after = ["test-alpha.service"];
          unitConfig = {
            ConditionUser = "tester";
            Requires = ["test-alpha.service"];
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = false;
            ExecStart = "${verifyScript} %t test-alpha";
          };
        };
        test-beta-verify = {
          after = ["test-beta.service"];
          unitConfig = {
            ConditionUser = "tester";
            Requires = ["test-beta.service"];
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = false;
            ExecStart = "${verifyScript} %t test-beta";
          };
        };
      };

      targets = {
        test-managed = {
          wantedBy = ["default.target"];
          wants = [
            "test-alpha-ready.target"
            "test-beta-ready.target"
          ];
          unitConfig.ConditionUser = "tester";
        };
        test-alpha-ready = {
          unitConfig = {
            ConditionUser = "tester";
            PartOf = ["test-alpha.service"];
            Requires = ["test-alpha-verify.service"];
            After = ["test-alpha-verify.service"];
          };
        };
        test-beta-ready = {
          unitConfig = {
            ConditionUser = "tester";
            PartOf = ["test-beta.service"];
            Requires = ["test-beta-verify.service"];
            After = ["test-beta-verify.service"];
          };
        };
      };
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("user@${toString uid}.service")

    ctl = "systemctl --user -M tester@"
    runtime_dir = "/run/user/${toString uid}"
    root = "test-managed.target"
    alpha = "test-alpha.service"
    alpha_ready = "test-alpha-ready.target"
    alpha_verify = "test-alpha-verify.service"
    beta = "test-beta.service"
    beta_ready = "test-beta-ready.target"

    def show(unit, prop):
        return machine.succeed(f"{ctl} show --property={prop} --value {unit}").strip()

    def verifier_count(service):
        return int(machine.succeed(f"cat {runtime_dir}/{service}-verify-count").strip())

    def assert_active(*units):
        machine.succeed(f"{ctl} is-active --quiet {' '.join(units)}")

    for unit in [root, alpha, alpha_ready, beta, beta_ready]:
        machine.wait_for_unit(unit, "tester")

    with subtest("root uses weak readiness edges with implicit target ordering"):
        root_wants = show(root, "Wants").split()
        root_requires = show(root, "Requires").split()
        root_after = show(root, "After").split()
        for ready in [alpha_ready, beta_ready]:
            assert ready in root_wants
            assert ready not in root_requires
            assert ready in root_after

    root_entered = show(root, "ActiveEnterTimestampMonotonic")
    alpha_pid = show(alpha, "MainPID")
    alpha_ready_entered = show(alpha_ready, "ActiveEnterTimestampMonotonic")
    beta_pid = show(beta, "MainPID")
    beta_ready_entered = show(beta_ready, "ActiveEnterTimestampMonotonic")
    assert verifier_count("test-alpha") == 1
    assert verifier_count("test-beta") == 1

    with subtest("restarting one service reruns only its readiness graph"):
        machine.succeed(f"{ctl} restart {alpha}")
        machine.wait_for_unit(alpha_ready, "tester")

        assert show(alpha, "MainPID") != alpha_pid
        assert show(alpha_ready, "ActiveEnterTimestampMonotonic") != alpha_ready_entered
        assert verifier_count("test-alpha") == 2
        assert show(root, "ActiveEnterTimestampMonotonic") == root_entered
        assert show(beta, "MainPID") == beta_pid
        assert show(beta_ready, "ActiveEnterTimestampMonotonic") == beta_ready_entered
        assert verifier_count("test-beta") == 1

    alpha_pid = show(alpha, "MainPID")

    with subtest("verifier failure is isolated from the root and sibling graph"):
        machine.succeed(f"touch {runtime_dir}/test-alpha-verify-fail")
        machine.execute(f"{ctl} restart {alpha}")
        machine.wait_until_succeeds(f"{ctl} is-failed --quiet {alpha_verify}")

        assert_active(root, alpha, beta, beta_ready)
        machine.fail(f"{ctl} is-active --quiet {alpha_ready}")
        assert show(alpha, "MainPID") != alpha_pid
        assert verifier_count("test-alpha") == 3
        assert show(root, "ActiveEnterTimestampMonotonic") == root_entered
        assert show(beta, "MainPID") == beta_pid
        assert show(beta_ready, "ActiveEnterTimestampMonotonic") == beta_ready_entered
        assert verifier_count("test-beta") == 1

    alpha_pid = show(alpha, "MainPID")

    with subtest("explicit root drain and resume owns the complete fleet"):
        machine.succeed(f"rm {runtime_dir}/test-alpha-verify-fail")
        machine.succeed(f"{ctl} reset-failed {alpha_verify} {alpha_ready}")
        machine.succeed(f"{ctl} stop {root}")
        for unit in [root, alpha, alpha_ready, beta, beta_ready]:
            machine.wait_until_succeeds(f"! {ctl} is-active --quiet {unit}")

        machine.succeed(f"{ctl} start {root}")
        for unit in [root, alpha, alpha_ready, beta, beta_ready]:
            machine.wait_for_unit(unit, "tester")

        assert show(alpha, "MainPID") != alpha_pid
        assert show(beta, "MainPID") != beta_pid
        assert verifier_count("test-alpha") == 4
        assert verifier_count("test-beta") == 2
  '';
}
