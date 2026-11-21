{pkgs}: let
  lib = pkgs.lib;
  permit = "/run/qualification-build-permit";
  node = useCgroups: {pkgs, ...}: {
    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
    nix = {
      package = pkgs.nixVersions.nix_2_34;
      settings = {
        experimental-features = ["nix-command"] ++ lib.optional useCgroups "cgroups";
        allowed-users = ["root" "builder"];
        trusted-users = ["root"];
        max-jobs = 1;
        cores = 1;
        substituters = lib.mkForce [];
        use-cgroups = useCgroups;
      };
    };
    users = {
      groups.build-clients = {};
      users = {
        builder = {
          isNormalUser = true;
          extraGroups = ["build-clients"];
        };
        outsider.isNormalUser = true;
      };
    };
    systemd = {
      slices.qualification-build.sliceConfig = {
        CPUQuota = "100%";
        MemoryHigh = "512M";
        MemoryMax = "768M";
        MemorySwapMax = 0;
        TasksMax = 128;
      };
      sockets.nix-daemon = {
        unitConfig.ConditionPathExists = permit;
        socketConfig = {
          SocketMode = lib.mkForce "0660";
          SocketGroup = "build-clients";
        };
      };
      services = {
        nix-daemon = {
          unitConfig.ConditionPathExists = permit;
          serviceConfig.Slice = "qualification-build.slice";
        };
        qualification-client = {
          unitConfig.ConditionPathExists = permit;
          serviceConfig = {
            User = "builder";
            Slice = "qualification-build.slice";
            ExecStart = "${pkgs.nixVersions.nix_2_34}/bin/nix build --store daemon --file /etc/blocked-build.nix --no-link --print-build-logs";
          };
        };
      };
    };
    environment = {
      systemPackages = [pkgs.procps pkgs.util-linux];
      etc = let
        expression = name: script: ''
          builtins.derivation {
            name = ${builtins.toJSON name};
            system = ${builtins.toJSON pkgs.stdenv.hostPlatform.system};
            builder = (builtins.storePath "${pkgs.bash}") + "/bin/bash";
            PATH = (builtins.storePath "${pkgs.coreutils}") + "/bin";
            args = [ "-c" ${builtins.toJSON script} ];
          }
        '';
      in {
        "blocked-build.nix".text = expression "containment-blocked" ''
          ${pkgs.coreutils}/bin/mkfifo "$TMPDIR/gate"
          echo 'CONTAINMENT_WORKER_READY' >&2
          exec ${pkgs.coreutils}/bin/cat "$TMPDIR/gate"
        '';
        "healthy-build.nix".text = expression "containment-recovered" ''
          echo recovered > "$out"
        '';
      };
    };
    services.openssh.enable = true;
    system.stateVersion = "26.05";
  };
in
  pkgs.testers.runNixOSTest {
    name = "nix-builder-shared-daemon-containment";
    nodes = {
      classic = node false;
      delegated = node true;
    };
    testScript = ''
      for machine in [classic, delegated]:
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("sshd.service")
          # Boot is closed until the supervisor has reconciled ownership.
          machine.succeed("test ! -e ${permit}")
          machine.succeed("systemctl start nix-daemon.socket nix-daemon.service")
          machine.fail("systemctl is-active nix-daemon.socket")
          machine.fail("systemctl is-active nix-daemon.service")
          machine.succeed("install -m 0600 /dev/null ${permit}; systemctl start nix-daemon.socket")
          machine.wait_for_unit("nix-daemon.socket")
          machine.succeed("runuser -u builder -- nix store ping --store daemon")
          machine.fail("runuser -u outsider -- nix store ping --store daemon")
          assert machine.succeed("systemctl show -p KillMode --value nix-daemon.service").strip() == "process"

          machine.succeed("systemctl start qualification-client.service")
          machine.wait_until_succeeds(
              "journalctl -b -u qualification-client.service --no-pager | grep -F CONTAINMENT_WORKER_READY",
              timeout=60,
          )
          group = machine.succeed("systemctl show -p ControlGroup --value qualification-build.slice").strip()
          assert group and group != "/"
          workers = machine.succeed("ps -eo pid,user | awk '$2 ~ /^nixbld/ {print $1}'").split()
          assert workers, "no real Nix build worker observed"
          for pid in workers:
              ancestry = machine.succeed(f"cat /proc/{pid}/cgroup").strip()
              assert ancestry.startswith(f"0::{group}/"), ancestry
          ssh_group = machine.succeed("systemctl show -p ControlGroup --value sshd.service").strip()
          assert not ssh_group.startswith(group + "/")
          machine.succeed(f"grep -Fx '100000 100000' /sys/fs/cgroup{group}/cpu.max")
          machine.succeed(f"grep -Fx 805306368 /sys/fs/cgroup{group}/memory.max")

          # An ordinary restart preserves live handlers; it is not cancellation.
          machine.succeed("systemctl restart nix-daemon.service")
          machine.succeed("systemctl is-active qualification-client.service")
          for pid in workers:
              machine.succeed(f"test -e /proc/{pid}/cgroup")
          machine.succeed("runuser -u builder -- nix store ping --store daemon")

          # Fence socket/restart ingress before terminating the accounted subtree.
          # Runtime masks cannot override NixOS units installed in /etc.
          machine.succeed("rm ${permit}; systemctl stop nix-daemon.socket nix-daemon.service")
          machine.succeed("systemctl start nix-daemon.socket nix-daemon.service")
          machine.fail("systemctl is-active nix-daemon.socket")
          machine.fail("systemctl is-active nix-daemon.service")
          machine.fail("runuser -u builder -- nix store ping --store daemon")
          machine.succeed(f"echo 1 > /sys/fs/cgroup{group}/cgroup.kill")
          machine.wait_until_succeeds(
              f"test ! -e /sys/fs/cgroup{group}/cgroup.events || grep -Fx 'populated 0' /sys/fs/cgroup{group}/cgroup.events",
              timeout=30,
          )
          for pid in workers:
              machine.wait_until_fails(f"test -e /proc/{pid}/cgroup", timeout=30)
          machine.succeed("systemctl is-active sshd.service")
          machine.succeed("systemctl start nix-daemon.socket nix-daemon.service qualification-client.service")
          for unit in ["nix-daemon.socket", "nix-daemon.service", "qualification-client.service"]:
              machine.fail(f"systemctl is-active {unit}")
          machine.fail("runuser -u builder -- nix store ping --store daemon")

          # Restore only after settlement; ordinary clients reuse the same store.
          machine.succeed("systemctl reset-failed nix-daemon.service qualification-client.service")
          machine.succeed("install -m 0600 /dev/null ${permit}; systemctl start nix-daemon.socket")
          output = machine.succeed(
              "runuser -u builder -- nix build --store daemon --file /etc/healthy-build.nix --no-link --print-out-paths"
          ).strip()
          assert output.startswith("/nix/store/")
          assert machine.succeed(f"cat {output}").strip() == "recovered"
          machine.succeed("systemctl is-active sshd.service")
          machine.log(machine.succeed("nix --version"))
          machine.shutdown()
    '';
  }
