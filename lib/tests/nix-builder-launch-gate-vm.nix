{pkgs}: let
  lib = pkgs.lib;
  # Match the parent target/profile so dependency artifacts remain reusable.
  # Cargo's artifact record supplies the executable path, including cross targets.
  example = package: name: pname:
    package.overrideAttrs (_: {
      pname = pname;
      buildPhase = ''
        runHook preBuild
        cargoBuildLog=$(mktemp cargoBuildLogXXXX.json)
        cargo build --offline --release --package ${package.pname} --example ${name} \
          --message-format json-render-diagnostics > "$cargoBuildLog"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        executable=$(${lib.getExe pkgs.jq} -ers '
          [.[] | select(.reason == "compiler-artifact" and .target.name == "${name}"
            and (.target.kind | index("example")) and .executable != null) | .executable]
          | if length == 1 then .[0] else error("expected one fixture executable") end
        ' "$cargoBuildLog")
        install -Dm755 "$executable" "$out/bin/${name}"
        runHook postInstall
      '';
    });
  # Only this test installs examples; supervised daemons use the installed CLI.
  driver = example pkgs.abird-host-agent "build-executor-gate" "build-executor-gate-qualification";
  preparation = example pkgs.abird-host-manager "build-prepare" "owned-native-preparation-qualification";
  preparationSource = let
    flake = native:
      pkgs.writeText "qualification-flake.nix" ''
        { outputs = _: let
          plan = name: builtins.derivation {
            name = "native-fixture-" + name;
            system = ${builtins.toJSON pkgs.stdenv.hostPlatform.system};
            builder = "${pkgs.bash}/bin/bash";
            args = [ "-c" "echo NATIVE_PREPARATION_MUST_NOT_BUILD >&2; exit 1" ];
          };
        in {
          nixbot.specialDependencies.app = [ "db" ];
          ${lib.optionalString native ''nixbot.plans = { db = plan "db"; app = plan "app"; alternate = plan "alternate"; };''}
          nixosConfigurations = {
            db.config.system.build.toplevel = plan "db";
            app.config.system.build.toplevel = plan "app";
          };
        }; }
      '';
    inventory = pkgs.writeText "qualification-inventory.nix" ''
      { stacks }: {
        config = {
          defaultGroup = stacks.fixture.group;
          defaultHosts = "app";
          deployDepsKey = "nixbot.specialDependencies";
        };
        hosts = {
          app.groups = [ "apps" ];
          db = {};
          external = { groups = [ "apps" ]; deploy = "skip"; };
        };
      }
    '';
    repositoryConfig = pkgs.writeText "qualification-config.nix" ''
      { stacks.fixture.group = "apps"; }
    '';
    overlay = pkgs.writeText "qualification-operator.nix" ''
      { stacks }: {
        config = { defaultGroup = stacks.fixture.group; defaultHosts = "external"; };
        hosts.app.target = "operator-override";
      }
    '';
  in
    pkgs.runCommand "owned-native-preparation-source" {} ''
      mkdir -p "$out/hosts" "$out/config" "$out/fallback"
      cp ${flake true} "$out/flake.nix"
      cp ${flake false} "$out/fallback/flake.nix"
      cp ${inventory} "$out/hosts/nixbot.nix"
      cp ${repositoryConfig} "$out/config/default.nix"
      cp ${overlay} "$out/operator.nix"
      printf 'throw "must not discover sibling overlay"\n' > "$out/hosts/nixbot.override.nix"
    '';
  tool = "${driver}/bin/build-executor-gate";
  home = "/var/lib/qualification";
  state = "${home}/.local/state/abird/abird-host-agent/owned-build";
  bootPermit = "/run/qualification-open";
  node = useCgroups: supervised: {pkgs, ...}: let
    nix = pkgs.nix;
    client = action: epoch: expression: "${tool} ${action} ${toString epoch} ${nix}/bin/nix 1000 1000 /etc/${expression}.nix";
    common = {
      Slice = "abird-build-owned.slice";
      TimeoutStopSec = "2s";
      Restart = "no";
    };
  in {
    imports = [../services/abird-host-agent];
    # Actual provisioning/daemon policy; the client and supervisor below remain
    # explicit fault injectors, not qualification of the installed Build worker.
    services = {
      abird-host-agent.buildExecutor = {
        enable = supervised;
        identity = {
          authority_id = "qualification";
          builder_id = "builder";
          store_id = "shared-store";
        };
        xdgStateHome = "${home}/.local/state";
        xdgDataHome = "${home}/.local/share";
        sourceUid = 1001;
        readerUid = 1000;
        readerGid = 1000;
        controlGid = 1002;
        principals.operator = {
          uid = 1100;
          issuer = "operator";
        };
        repositories.fixture = "https://fixture.invalid/repository.git";
        gitConfiguration = pkgs.writeText "qualification-git-config" "[safe]\n\tdirectory = *\n";
        resources = {
          cpu_quota_micros = 100000;
          cpu_period_micros = 100000;
          memory_high = 536870912;
          memory_max = 805306368;
          swap_max = 0;
          tasks_max = 128;
          min_store_free_bytes = 33554432;
          min_state_free_bytes = 33554432;
        };
        controlReserve = {
          memory_max = 134217728;
          tasks_max = 64;
          cpu_percent = 5;
        };
        sourceLimits = {
          entries = 32768;
          bytes = 16777216;
          depth = 64;
        };
        deadlines = {
          heartbeat_seconds = 2;
          stale_seconds = 6;
          owner_seconds = 12;
          queue_seconds = 60;
          runtime_seconds = 600;
          stop_grace_seconds = 8;
          stop_limit_seconds = 30;
          retention_seconds = 60;
        };
        maxJobs = 1;
        maxCores = 1;
        submissionAgeSeconds = 60;
        futureSkewSeconds = 2;
        replaySeconds = 120;
        controlTimeoutMillis = 2000;
        maxConnections = 4;
        connectionLifetimeSeconds = 15;
        # Unauthorized peers reach SO_PEERCRED only in this disposable test.
        control.users =
          lib.mkIf supervised
          (lib.mkForce ["operator" "abird-owned-builder" "outsider"]);
      };
      openssh.enable = true;
    };
    virtualisation = {
      cores = 2;
      memorySize = 2048;
      # Disposable backing only: 9p exposes unregistered host paths which GC
      # whiteouts. Each guest still has one shared store/database/daemon.
      useNixStoreImage = supervised;
      # Preserve the previous writable overlay; image-backed defaults are RO.
      writableStore = true;
    };
    nix = {
      package = nix;
      settings = {
        experimental-features = ["nix-command" "flakes"] ++ lib.optional useCgroups "cgroups";
        # Hostile fixture baseline: the installed role must override both lists.
        allowed-users =
          if supervised
          then ["*"]
          else ["root" "builder"];
        trusted-users =
          if supervised
          then ["*"]
          else ["root"];
        use-cgroups = useCgroups;
        max-jobs = 1;
        cores = 1;
        min-free = 0;
        substituters = lib.mkForce [];
      };
    };
    users = {
      groups.builder = lib.mkIf (!supervised) {gid = 1000;};
      users = {
        builder = lib.mkIf (!supervised) {
          isNormalUser = true;
          uid = 1000;
          group = "builder";
        };
        outsider.isNormalUser = true;
        operator = {
          isNormalUser = true;
          uid = 1100;
        };
      };
    };
    systemd = {
      tmpfiles.rules = lib.optionals supervised [
        "d /home/builder 0700 abird-owned-builder abird-owned-readers -"
      ];
      slices.abird-build.sliceConfig = lib.mkIf (!supervised) {
        CPUQuota = "100%";
        MemoryHigh = "512M";
        MemoryMax = "768M";
        MemorySwapMax = 0;
        TasksMax = 128;
      };
      sockets.nix-daemon = {
        unitConfig.ConditionPathExists = bootPermit;
        socketConfig = {
          SocketMode = lib.mkForce (
            if supervised
            then "0600"
            else "0660"
          );
          SocketUser = lib.mkIf supervised "abird-owned-builder";
          SocketGroup =
            if supervised
            then "abird-owned-readers"
            else "builder";
        };
      };
      services = {
        # Bootstrap is real and one-shot; fixture control starts only explicitly.
        abird-owned-build-bootstrap = lib.mkIf supervised {
          unitConfig.OnSuccess = lib.mkForce [];
          # Disposable declarations contain no private caller payload.
          serviceConfig.StandardError = lib.mkForce "journal";
        };
        abird-owned-build-supervisor = lib.mkIf supervised {wantedBy = lib.mkForce [];};
        nix-daemon = {
          environment =
            {
              OB_GATE_HOME = home;
              XDG_STATE_HOME = "${home}/.local/state";
            }
            // lib.optionalAttrs supervised {
              OB_DAEMON_PRIVATE_SENTINEL = "must-not-reach-native-daemon";
              NIX_CONFIG = "untrusted-policy-sentinel = true";
            };
          unitConfig.ConditionPathExists = bootPermit;
          serviceConfig =
            common
            // {
              ExecStart = lib.mkIf (!supervised) (lib.mkForce ["" "${tool} daemon ${nix}/bin/nix-daemon"]);
              StandardOutput = lib.mkForce "journal";
              StandardError = lib.mkForce "journal";
            };
        };
        "abird-build-client@" = {
          after = ["nix-daemon.socket"];
          requires = lib.optionals (!supervised) ["nix-daemon.socket"];
          environment = {
            OB_GATE_HOME = home;
            OB_NATIVE_PREPARATION = "${preparation}/bin/build-prepare";
            OB_NATIVE_MANAGER = "${pkgs.abird-host-manager}/libexec/abird-host-manager";
            OB_NATIVE_PREPARATION_SOURCE = preparationSource;
            OB_PRIVATE_GIT = "${pkgs.git}/bin/git";
            XDG_DATA_HOME = "${home}/.local/share";
          };
          serviceConfig =
            common
            // {
              ExecStart = lib.mkForce "${tool} supervised-client %i ${nix}/bin/nix";
              TimeoutStopSec = lib.mkForce (
                if supervised
                then "8s"
                else "2s"
              );
              RemainAfterExit = true;
              KillMode = "process";
              ReadWritePaths = ["/run"];
              ProtectHome = lib.mkForce false;
              StandardOutput = lib.mkForce "journal";
              StandardError = lib.mkForce "journal";
            };
        };
        qualification-helper = {
          environment.OB_GATE_HOME = home;
          serviceConfig =
            common
            // {
              ExecStart = "${tool} supervised-helper ${pkgs.coreutils}/bin/cat /run/qualification-helper-fifo";
            };
        };
        qualification-root-gc = {
          environment.OB_GATE_HOME = home;
          serviceConfig =
            common
            // {
              Type = "oneshot";
              TimeoutStartSec = "30s";
              ExecStart = "${tool} supervised-gc ${nix}/bin/nix-store";
            };
        };
        # Fault injector only: blocks native GC, never runs collection itself.
        qualification-gc-lock = {
          serviceConfig = {
            ExecStart = "${pkgs.util-linux}/bin/flock --exclusive /nix/var/nix/gc.lock ${pkgs.runtimeShell} -c 'touch /run/qualification-gc-lock-ready; exec ${pkgs.coreutils}/bin/cat /run/qualification-gc-lock-hold'";
            Restart = "no";
            UMask = "0077";
          };
          path = [pkgs.coreutils];
        };
        qualification-supervisor = {
          environment.OB_GATE_HOME = home;
          serviceConfig = {
            ExecStart = "${tool} supervised-poll ${pkgs.systemd}/bin/systemctl";
            Restart = "no";
          };
        };
        qualification-probe = {
          environment.OB_GATE_HOME = home;
          serviceConfig =
            common
            // {
              Type = "oneshot";
              TimeoutStartSec = "30s";
              ExecStart = "${tool} probe ${nix}/bin/nix 1000 1000";
            };
        };
        qualification-pending = {
          environment.OB_GATE_HOME = home;
          serviceConfig = common // {ExecStart = client "pending" 1 "blocked-build";};
        };
        qualification-active = {
          environment.OB_GATE_HOME = home;
          serviceConfig = common // {ExecStart = client "client" 2 "blocked-build";};
        };
        qualification-healthy = {
          environment.OB_GATE_HOME = home;
          serviceConfig = common // {ExecStart = client "client" 3 "healthy-build";};
        };
        qualification-fencer = {
          environment.OB_GATE_HOME = home;
          # Deliberately outside the killable slice.
          serviceConfig = {
            ExecStart = "${tool} fence";
            Restart = "no";
          };
        };
      };
    };
    environment = {
      systemPackages = [driver pkgs.procps pkgs.python3];
      variables.OB_GATE_HOME = home;
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
        "qualification-gc-observe.py".text = ''
          import json, os, pathlib, re, select, signal, sys

          def read(path, limit=4096):
              with open(path) as f:
                  value = f.read(limit + 1)
              assert len(value) <= limit
              return value

          def snapshot(pid):
              root = pathlib.Path("/proc") / str(pid)
              return {"pid": pid,
                      "start": read(root / "stat").rpartition(") ")[2].split()[19],
                      "exe": os.readlink(root / "exe"),
                      "cgroup": read(root / "cgroup").strip()}

          mode, unit = sys.argv[1:3]
          assert re.fullmatch(r"abird-build-client@[a-f0-9]{64}\.service", unit)
          client = "0::/abird.slice/abird-build.slice/abird-build-owned.slice/" + unit
          daemon = "0::/abird.slice/abird-build.slice/abird-build-owned.slice/nix-daemon.service"
          agent_exe = os.path.realpath("${pkgs.abird-host-agent}/bin/abird-host-agent")
          native_exe = os.path.realpath("${nix}/bin/nix-daemon")
          if mode == "worker":
              result = snapshot(int(read("/run/qualification-maintenance-worker-pid")))
              assert result["exe"] == agent_exe and result["cgroup"] == client
          elif mode == "client":
              worker = int(read("/run/qualification-maintenance-worker-pid"))
              children = read(pathlib.Path("/proc") / str(worker) / "task" / str(worker) / "children").split()
              assert len(children) == 1
              result = snapshot(int(children[0]))
              assert result["exe"] == native_exe and result["cgroup"] == client
              status = dict(line.split(":", 1) for line in read(pathlib.Path("/proc") / str(result["pid"]) / "status").splitlines())
              assert status["Uid"].split() == ["1000"] * 4
              assert status["Gid"].split() == ["1000"] * 4
              assert not status["Groups"].split()
              assert int(status["CapEff"], 16) == 0 and status["NoNewPrivs"].strip() == "1"
              assert not os.path.lexists(f"/proc/{result['pid']}/fd/190")
              environment = (pathlib.Path("/proc") / str(result["pid"]) / "environ").read_bytes()
              assert len(environment) <= 65536
              names = {entry.split(b"=", 1)[0] for entry in environment.split(b"\0") if entry}
              assert names == {b"HOME", b"LC_ALL", b"PATH", b"NIX_CONF_DIR", b"NIX_SSL_CERT_FILE"}
          elif mode == "waiter":
              st = os.stat("/nix/var/nix/gc.lock")
              key = (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
              found = []
              for line in read("/proc/locks", 65536).splitlines():
                  fields = line.split()
                  if len(fields) != 9 or fields[1:5] != ["->", "FLOCK", "ADVISORY", "WRITE"]:
                      continue
                  major, minor, inode = fields[6].split(":")
                  if (int(major, 16), int(minor, 16), int(inode)) != key:
                      continue
                  item = snapshot(int(fields[5]))
                  assert item["exe"] == native_exe
                  assert item["cgroup"] == daemon or item["cgroup"].startswith(daemon + "/")
                  found.append(item)
              assert len(found) == 1
              result = found[0]
          elif mode == "gone":
              expected = json.loads(sys.argv[3])
              try:
                  fd = os.pidfd_open(expected["pid"])
              except ProcessLookupError:
                  result = {"exited": True}
              else:
                  try:
                      poll = select.poll()
                      poll.register(fd, select.POLLIN)
                      events = poll.poll(0)
                      if events:
                          assert len(events) == 1 and events[0][0] == fd
                          assert events[0][1] & (select.POLLIN | select.POLLHUP)
                      else:
                          # A different start proves PID reuse, not survival.
                          stat = read(pathlib.Path("/proc") / str(expected["pid"]) / "stat")
                          assert stat.rpartition(") ")[2].split()[19] != expected["start"]
                      result = {"exited": True}
                  finally:
                      os.close(fd)
          elif mode in ["alive", "kill-worker"]:
              expected = json.loads(sys.argv[3])
              fd = os.pidfd_open(expected["pid"])
              try:
                  result = snapshot(expected["pid"])
                  assert result == expected
                  if mode == "kill-worker":
                      assert result["exe"] == agent_exe and result["cgroup"] == client
                      signal.pidfd_send_signal(fd, signal.SIGKILL)
              finally:
                  os.close(fd)
          else:
              raise AssertionError("unknown fixture observation")
          print(json.dumps(result, sort_keys=True))
        '';
        "blocked-build.nix".text = expression "gated-blocked" ''
          mkfifo "$TMPDIR/gate"
          echo GATED_WORKER_READY >&2
          exec cat "$TMPDIR/gate"
        '';
        "healthy-build.nix".text = expression "gated-recovered" ''
          echo recovered > "$out"
        '';
        "protected-build.nix".text = expression "rooted-never-realised" ''
          echo ROOTING_MUST_NOT_BUILD >&2
          echo unexpected > "$out"
        '';
      };
    };
    system.stateVersion = "26.05";
  };
in
  pkgs.testers.runNixOSTest {
    name = "nix-builder-launch-fence-interlock";
    nodes = {
      classic = node false false;
      delegated = node true false;
      supervisedClassic = node false true;
      supervisedDelegated = node true true;
      protectedClassic = node false true;
      protectedDelegated = node true true;
      collectorDeathClassic = node false true;
      collectorDeathDelegated = node true true;
    };
    testScript = ''
      import json
      import shlex
      import base64
      import traceback

      expected_args = [b"--daemon", b"--option", b"allowed-users", b"abird-owned-builder", b"--option", b"trusted-users", b"root", b"--option", b"min-free", b"0", b"--option", b"system", b"${pkgs.stdenv.hostPlatform.system}"]

      def control(machine, user, command):
          message = json.dumps({"version": 3, "command": command})
          result = machine.succeed(f"printf %s {shlex.quote(message)} | runuser -u {user} -- build-executor-gate control-request /run/abird/abird-host-agent/owned-build/control.sock")
          return json.loads(result)["reply"]

      def installed_bootstrap(machine):
          # Pin the initially registered VM substrate before job inputs exist.
          # The closure-only backing image excludes unrelated unregistered paths;
          # these administrative fixture roots are outside owned job protection.
          machine.succeed("mkdir -m 0700 /nix/var/nix/gcroots/qualification-seed; ${pkgs.nix}/bin/nix --store local path-info --all | while IFS= read -r path; do ln -s \"$path\" \"/nix/var/nix/gcroots/qualification-seed/$(basename \"$path\")\"; done")
          code, output = machine.execute("build-executor-gate supervised-init ${pkgs.systemd}/bin/systemctl")
          if code != 0:
              machine.log(output)
              machine.log(machine.succeed("journalctl -b -u abird-owned-build-bootstrap.service --no-pager -o cat"))
          assert code == 0, "installed one-shot bootstrap failed"

      def installed_cleanup(machine):
          # Same queue/worker, separately admitted Retirement, actual unit policy.
          # Wait for original resources + cleanup settlement, not just CLI exit.
          machine.succeed("systemctl start abird-owned-build-supervisor.service")
          check = "import json; s=json.load(open('${state}/state.json'))['state']; assert s['pool']['owner'] is None; assert any(j.get('retirement',{}).get('complete') for j in s['jobs'] if j.get('retirement')); assert all(j['settled_at'] is not None for j in s['jobs'])"
          machine.wait_until_succeeds(f"python3 -c {shlex.quote(check)} && build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=true", timeout=60)
          machine.succeed("systemctl stop abird-owned-build-supervisor.service")

      def hold_gc(machine):
          machine.succeed("mkfifo -m 0600 /run/qualification-gc-lock-hold; systemctl start qualification-gc-lock.service")
          machine.wait_until_succeeds("test -f /run/qualification-gc-lock-ready", timeout=60)

      def collector_waiting(machine, unit):
          observe = "python3 /etc/qualification-gc-observe.py"
          machine.wait_until_succeeds(f"{observe} waiter {shlex.quote(unit)} && {observe} client {shlex.quote(unit)}", timeout=60)
          machine.log("UPSTREAM_COLLECTOR_UNPRIVILEGED_NO_CAPABILITIES_OR_INHERITED_AUTHORITY_FD")

      def launch_interlock(machine):
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("sshd.service")
          machine.succeed("build-executor-gate init; mkfifo ${state}/release-start ${state}/release-fence")
          machine.succeed("build-executor-gate grant 0; install -m 0600 /dev/null ${bootPermit}; systemctl start nix-daemon.socket")
          machine.succeed("systemctl start qualification-probe.service")
          machine.fail("runuser -u outsider -- nix store ping --store daemon")

          # The old unit has passed systemd dispatch but not the exec interlock.
          machine.succeed("build-executor-gate grant 1; systemctl start --no-block qualification-pending.service")
          machine.wait_until_succeeds("test -f ${state}/pending-entered", timeout=60)
          machine.succeed("build-executor-gate grant 2; echo x > ${state}/release-start")
          machine.wait_until_succeeds("systemctl is-failed qualification-pending.service", timeout=60)
          machine.fail("journalctl -b -u qualification-pending.service --no-pager | grep -F GATED_WORKER_READY")

          machine.succeed("systemctl start qualification-active.service")
          machine.wait_until_succeeds("journalctl -b -u qualification-active.service --no-pager | grep -F GATED_WORKER_READY", timeout=60)
          group = machine.succeed("systemctl show -p ControlGroup --value abird-build.slice").strip()
          workers = machine.succeed("ps -eo pid,user | awk '$2 ~ /^nixbld/ {print $1}'").split()
          assert group and workers
          for pid in workers:
              assert machine.succeed(f"cat /proc/{pid}/cgroup").strip().startswith(f"0::{group}/")
          main_pid = machine.succeed("systemctl show -p MainPID --value qualification-active.service").strip()
          assert machine.succeed(f"ps -o user= -p {main_pid}").strip() == "builder"

          # A running worker cannot retain the start interlock until exit.
          machine.succeed("systemctl start qualification-fencer.service")
          machine.wait_until_succeeds("journalctl -b -u qualification-fencer.service --no-pager -o cat | grep -Fx FENCED", timeout=60)
          machine.succeed("test ! -e ${state}/launch/permit.json; systemctl is-active qualification-active.service")
          machine.succeed("rm ${bootPermit}; systemctl stop nix-daemon.socket nix-daemon.service")
          machine.succeed("echo k > ${state}/release-fence")
          machine.wait_until_succeeds("journalctl -b -u qualification-fencer.service --no-pager -o cat | grep -Fx SETTLED", timeout=60)
          machine.wait_until_succeeds(f"test ! -e /sys/fs/cgroup{group}/cgroup.events || grep -Fx 'populated 0' /sys/fs/cgroup{group}/cgroup.events", timeout=60)
          for pid in workers:
              machine.wait_until_fails(f"test -e /proc/{pid}", timeout=30)
          machine.succeed("systemctl is-active qualification-fencer.service sshd.service")
          machine.succeed("systemctl start qualification-active.service")
          machine.wait_until_succeeds("systemctl is-failed qualification-active.service", timeout=60)
          machine.succeed("systemctl kill --signal=KILL qualification-fencer.service")
          machine.wait_until_succeeds("systemctl is-failed qualification-fencer.service", timeout=60)
          machine.succeed("test ! -e ${state}/launch/permit.json")
          machine.succeed("systemctl start qualification-active.service")
          machine.wait_until_succeeds("systemctl is-failed qualification-active.service", timeout=60)

          machine.succeed("systemctl reset-failed; build-executor-gate grant 0; install -m 0600 /dev/null ${bootPermit}; systemctl start nix-daemon.socket")
          machine.succeed("systemctl start qualification-probe.service")
          machine.succeed("build-executor-gate grant 3; systemctl start qualification-healthy.service")
          machine.wait_until_succeeds("test $(systemctl show -p ActiveState --value qualification-healthy.service) = inactive && test $(systemctl show -p Result --value qualification-healthy.service) = success && journalctl -b -u qualification-healthy.service --no-pager -o cat | grep -E '^/nix/store/[0-9a-z]{32}-gated-recovered$'", timeout=60)
          output = machine.succeed("journalctl -b -u qualification-healthy.service --no-pager -o cat | grep -E '^/nix/store/[0-9a-z]{32}-gated-recovered$'").strip()
          assert machine.succeed(f"cat {output}").strip() == "recovered"
          machine.succeed("systemctl start qualification-active.service")
          machine.wait_until_succeeds("systemctl is-failed qualification-active.service", timeout=60)
          machine.succeed("systemctl is-active sshd.service")

      def supervised_lifecycle(machine):
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("sshd.service")
          machine.wait_for_unit("abird-owned-build-control.socket")
          role = json.loads(machine.succeed("cat /etc/abird-owned-build/role.json"))
          assert role["version"] == 2
          assert role["manager_program"] == "${pkgs.abird-host-manager}/libexec/abird-host-manager"
          assert not ({"source_program", "prepare_program", "request_program", "capture_program"} & set(role["build"]))
          assert "program" not in role["controller"]
          assert machine.succeed("od -An -N4 -tx1 ${pkgs.abird-host-manager}/libexec/abird-host-manager").strip() == "7f 45 4c 46"
          machine.log("OWNED_MODES_USE_MANAGER_BINARY_WITHOUT_CALLER_WRAPPER")
          missing = control(machine, "operator", {"kind": "status", "attempt_id": "a" * 64})
          assert missing["kind"] == "unconfirmed"
          machine.succeed("test ! -e ${state}")
          installed_bootstrap(machine)
          machine.succeed("mkfifo -m 0666 /run/qualification-helper-fifo")
          unit = machine.succeed("build-executor-gate supervised-prepare").strip()
          # Root wrappers must be able to drop credentials, without ambient caps
          # or removal of NoNewPrivileges/address-family restrictions.
          for role_unit in [unit, "abird-owned-fleet@abird-owned-definition.service"]:
              assert not machine.succeed(f"systemctl show {role_unit} -p User --value").strip()
              assert machine.succeed(f"systemctl show {role_unit} -p Group --value").strip() == "root"
              assert not machine.succeed(f"systemctl show {role_unit} -p AmbientCapabilities --value").strip()
              assert machine.succeed(f"systemctl show {role_unit} -p NoNewPrivileges --value").strip() == "yes"
              assert machine.succeed(f"systemctl show {role_unit} -p RestrictAddressFamilies --value").strip()
          machine.fail("runuser -u abird-owned-builder -- test -r ${state}/client-expression")
          machine.succeed("systemctl start qualification-supervisor.service")
          machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager | grep -F GATED_WORKER_READY", timeout=60)
          workers = machine.succeed("ps -eo pid,user | awk '$2 ~ /^nixbld/ {print $1}'").split()
          assert workers
          daemon_pid = machine.succeed("systemctl show nix-daemon -p MainPID --value").strip()
          native_env = dict(entry.split(b"=", 1) for entry in base64.b64decode(machine.succeed(f"base64 -w0 /proc/{daemon_pid}/environ")).split(b"\0") if entry)
          assert set(native_env) == {b"HOME", b"LC_ALL", b"PATH", b"NIX_CONF_DIR", b"NIX_SSL_CERT_FILE", b"LISTEN_PID", b"LISTEN_FDS"}
          assert native_env[b"LISTEN_PID"] == daemon_pid.encode() and native_env[b"LISTEN_FDS"] == b"1"
          assert native_env[b"HOME"] == b"/var/empty"
          assert native_env[b"NIX_CONF_DIR"].startswith(b"/nix/store/")
          assert native_env[b"NIX_SSL_CERT_FILE"].startswith(b"/nix/store/")
          machine.log("INSTALLED_DAEMON_NATIVE_ACTIVATION_AND_ENVIRONMENT")
          ledger = json.loads(machine.succeed("cat ${state}/state.json"))["state"]
          claim = ledger["jobs"][0]["daemon_claim"]
          assert ledger["version"] == 14 and claim["handle"]["ownership"] == ledger["pool"]["owner"]
          assert claim["handle"]["invocation_id"] == machine.succeed("systemctl show nix-daemon.service --property=InvocationID --value").strip()
          assert ledger["jobs"][0]["reserved_at"] <= claim["claimed_at"] <= ledger["last_time"]
          machine.log("INSTALLED_DAEMON_INVOCATION_DURABLY_CLAIMED")
          machine.succeed("test $(stat -c %a /nix/var/nix/daemon-socket/socket) = 600 && test $(stat -c %u /nix/var/nix/daemon-socket/socket) = 1000")
          native_args = base64.b64decode(machine.succeed(f"base64 -w0 /proc/{daemon_pid}/cmdline")).split(b"\0")
          assert native_args[1:-1] == expected_args
          for user, trusted in [("abird-owned-builder", False), ("root", True)]:
              machine.succeed(f"systemd-run --quiet --wait --pipe --unit=qualification-native-info-{user} --property=Slice=abird-build.slice --uid={user} /run/current-system/sw/bin/nix store info --store daemon --json > /run/qualification-native-info-{user}.json")
              info = json.loads(machine.succeed(f"cat /run/qualification-native-info-{user}.json"))
              assert info["trusted"] is trusted
          # Same reader group is insufficient, including for the source actor.
          for user in ["operator", "outsider", "abird-owned-source"]:
              machine.fail(f"systemd-run --quiet --wait --pipe --unit=qualification-native-denied-{user} --property=Slice=abird-build.slice --uid={user} /run/current-system/sw/bin/nix store info --store daemon --json --option trusted-users '*' --option allowed-users '*'")
          assert machine.succeed("systemctl show nix-daemon.service --property=MainPID --value").strip() == daemon_pid
          machine.log("UPSTREAM_NATIVE_SOCKET_EXCLUDES_SOURCE_AND_CALLER_UIDS")
          producer_request = json.dumps({"version": 3, "command": {"kind": "status", "attempt_id": "a" * 64}})
          producer_reply = machine.succeed(f"printf %s {shlex.quote(producer_request)} | systemd-run --quiet --wait --pipe --collect --unit=qualification-producer-control --property=Slice=abird-build.slice --uid=operator ${tool} control-request /run/abird/abird-host-agent/owned-build/control.sock")
          assert json.loads(producer_reply)["reply"] == {"kind": "rejected", "code": "unauthorized"}
          machine.log("SOURCE_CALLER_UID_CANNOT_REENTER_CONTROL_FROM_WORKLOAD")
          before_gc = json.loads(machine.succeed("cat ${state}/state.json"))["state"]
          assert len(before_gc["jobs"]) == 1 and before_gc["jobs"][0]["request"]["kind"] == "build"
          assert before_gc["jobs"][0]["attempt"]["state"]["kind"] == "running"
          children_path = f"/proc/{daemon_pid}/task/{daemon_pid}/children"
          machine.wait_until_succeeds(f"test $(wc -w < {children_path}) -eq 1", timeout=30)
          children = machine.succeed(f"cat {children_path}").strip()
          assert children.isdigit()
          machine.succeed("printf '%s' native-gc-query-sentinel > /run/qualification-gc-candidate")
          probe = "systemd-run --quiet --wait --pipe --property=Slice=abird-build.slice --property=RuntimeMaxSec=30s --property=TimeoutStopSec=3s --uid=abird-owned-builder"
          candidate = machine.succeed(f"{probe} --unit=qualification-gc-candidate /run/current-system/sw/bin/nix-store --store daemon --add /run/qualification-gc-candidate").strip()
          assert candidate.startswith("/nix/store/") and candidate.endswith("-qualification-gc-candidate")
          # Deliberate executor compromise in a disposable VM. Upstream has no
          # per-job operation filter: Nix-untrusted does not mean GC-ineligible.
          dead = machine.succeed(f"{probe} --unit=qualification-gc-query /run/current-system/sw/bin/nix-store --store daemon --gc --print-dead").splitlines()
          assert candidate in dead
          machine.succeed(f"{probe} --unit=qualification-gc-delete /run/current-system/sw/bin/nix-store --store daemon --delete {shlex.quote(candidate)}")
          machine.fail(f"test -e {shlex.quote(candidate)}")
          machine.wait_until_succeeds(f"test \"$(cat {children_path})\" = {shlex.quote(children + ' ')}", timeout=30)
          after_gc = json.loads(machine.succeed("cat ${state}/state.json"))["state"]
          assert len(after_gc["jobs"]) == 1
          for field in ["request", "reserved_at", "attempt", "daemon_claim", "release_digest"]:
              assert after_gc["jobs"][0][field] == before_gc["jobs"][0][field]
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=false")
          assert machine.succeed("systemctl show nix-daemon.service --property=MainPID --value").strip() == daemon_pid
          machine.log("UPSTREAM_EXECUTOR_COMPROMISE_CAN_GC_WITHOUT_MAINTENANCE")
          # Known, admitted helper pins the aggregate population even if Nix
          # settles naturally during grace. It must die with the whole workload.
          machine.succeed("systemctl start qualification-helper.service")
          machine.wait_for_unit("qualification-helper.service")
          job_property = machine.succeed(f"systemctl show --property=Job -- {unit}").strip()
          assert job_property in ["Job=", "Job=0"]
          key = unit.removeprefix("abird-build-client@").removesuffix(".service")
          status_request = {"kind": "status", "attempt_id": key}
          for user in ["abird-owned-builder", "outsider"]:
              rejected = control(machine, user, status_request)
              assert rejected == {"kind": "rejected", "code": "unauthorized"}
          status = control(machine, "operator", status_request)
          assert status["kind"] == "status" and status["snapshot"]["phase"] == "running"
          # Installed unprivileged caller over real SSH. Each observation closes
          # its connection; reconnect must retain the original running attempt.
          machine.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /run/qualification-operator-key")
          machine.succeed("install -d -o operator -m 0700 /home/operator/.ssh && install -o operator -m 0600 /run/qualification-operator-key.pub /home/operator/.ssh/authorized_keys")
          machine.succeed("ssh-keyscan -t ed25519 127.0.0.1 > /run/qualification-known-hosts")
          # No request body: SSH must not consume the test driver's shell input.
          # Observation timeout stops this connection, never the remote attempt.
          ssh_control = "timeout --kill-after=2s 20s ssh -n -T -F /dev/null -i /run/qualification-operator-key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/qualification-known-hosts -o ControlMaster=no -o ControlPath=none operator@127.0.0.1 /run/current-system/sw/bin/abird-host-agent --json owned-build"
          for _ in range(2):
              reconnected = json.loads(machine.succeed(f"{ssh_control} status {key}"))
              assert reconnected["version"] == 3 and reconnected["reply"] == status
              assert machine.succeed("systemctl show nix-daemon.service --property=MainPID --value").strip() == daemon_pid
              machine.succeed(f"kill -0 {children}")
          page = json.loads(machine.succeed(f"{ssh_control} events {key} --limit 1"))["reply"]
          assert page["kind"] == "events" and page["page"]["next"]["attempt_id"] == key
          assert len(page["page"]["events"]) == 1
          diagnostic = json.loads(machine.succeed(f"{ssh_control} logs {key} --limit 512"))["reply"]
          assert diagnostic["kind"] == "logs" and not diagnostic["page"]["sealed"]
          assert not diagnostic["page"]["gap"] and len(diagnostic["page"]["bytes"]) == 512
          first_event = json.loads(bytes(diagnostic["page"]["bytes"]))
          assert first_event["sequence"] == 1 and first_event["detail"]["kind"] == "accepted"
          continuation = diagnostic["page"]["next"]
          assert continuation["attempt_id"] == key and continuation["generation"] == "journal14"
          assert continuation["offset"] == 512
          resumed_log = json.loads(machine.succeed(f"{ssh_control} logs {key} --generation {continuation['generation']} --offset {continuation['offset']} --limit 512"))["reply"]["page"]
          assert not resumed_log["gap"] and resumed_log["next"]["offset"] == 1024
          assert json.loads(bytes(resumed_log["bytes"]))["sequence"] == 2
          for user in ["abird-owned-builder", "outsider"]:
              denied = control(machine, user, {"kind": "logs", "attempt_id": key, "cursor": None, "limit": 512})
              assert denied == {"kind": "rejected", "code": "unauthorized"}
          machine.log("INSTALLED_CALLER_SSH_RECONNECTS_TO_ORIGINAL_RUNNING_ATTEMPT")
          stopped = json.loads(machine.succeed(f"{ssh_control} cancel {key}"))["reply"]
          assert stopped == {"kind": "stop_requested", "attempt_id": key}
          machine.log("INSTALLED_CALLER_SSH_CANCEL_ACK_IS_NOT_SETTLEMENT")
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F terminating", timeout=60)
          before = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert before["phase"] == "stopping" and before["outcome"] is None
          machine.succeed("systemctl kill --signal=KILL qualification-supervisor.service")
          machine.wait_until_succeeds("systemctl is-failed qualification-supervisor.service", timeout=60)
          # Observation/cancellation remains available while the controller is dead.
          after = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert before["stop"] == after["stop"]
          retained_log = json.loads(machine.succeed(f"{ssh_control} logs {key} --limit 8192"))["reply"]["page"]
          assert not retained_log["sealed"] and retained_log["next"]["attempt_id"] == key
          assert any(json.loads(line)["detail"]["kind"] == "stop_requested" for line in bytes(retained_log["bytes"]).splitlines())
          machine.log("INSTALLED_DIAGNOSTICS_SURVIVE_DISCONNECT_AND_SUPERVISOR_LOSS")
          observed = control(machine, "operator", status_request)
          assert observed["snapshot"]["phase"] == "stopping" and observed["snapshot"]["outcome"] is None
          machine.succeed("test ! -e ${state}/launch/permit.json; systemctl is-active sshd.service")
          machine.succeed("systemctl reset-failed qualification-supervisor.service; systemctl start qualification-supervisor.service")
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F cancelled", timeout=60)
          settled = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert settled["phase"] == "cancelled" and settled["outcome"]["kind"] == "cancelled" and settled["pool"] == "recovering"
          caller_settled = json.loads(machine.succeed(f"{ssh_control} status {key}"))["reply"]["snapshot"]
          assert caller_settled["phase"] == "cancelled" and caller_settled["outcome"]["kind"] == "cancelled"
          assert caller_settled["ownership"] == status["snapshot"]["ownership"]
          closed_log = json.loads(machine.succeed(f"{ssh_control} logs {key} --limit 8192"))["reply"]["page"]
          assert closed_log["sealed"]
          assert caller_settled["outcome"]["kind"] != "succeeded"
          machine.log("INSTALLED_CALLER_OBSERVES_CANCELLATION_ONLY_AFTER_SETTLEMENT")
          for pid in workers:
              machine.wait_until_fails(f"test -e /proc/{pid}", timeout=30)
          machine.succeed("test ! -e ${state}/launch/permit.json; systemctl is-active sshd.service")
          # Fresh healthy client exits zero, but absent verified preparation must
          # settle as verification failure, never success or a compiler failure.
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = inactive", timeout=60)
          machine.succeed("build-executor-gate supervised-prepare healthy")
          machine.succeed("systemctl start qualification-supervisor.service")
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F verification_failed", timeout=60)
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F recovering", timeout=60)
          observed = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert observed["phase"] == "failed"
          assert observed["outcome"]["reason"]["kind"] == "verification_failed"
          machine.succeed("test ! -e ${state}/launch/permit.json; systemctl is-active sshd.service")

      def protection_and_sources(machine):
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("sshd.service")
          installed_bootstrap(machine)
          machine.succeed("mkfifo -m 0600 /run/qualification-roots-hold /run/qualification-before-roots")
          unit = machine.succeed("build-executor-gate supervised-prepare protected").strip()
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=true")
          machine.succeed("systemctl start qualification-supervisor.service")
          machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx BEFORE_ROOT_PUBLICATION", timeout=60)
          machine.succeed("test ! -e ${state}/root-info.json; test ! -e /run/qualification-root-source")
          machine.succeed("systemctl kill --kill-whom=main --signal=KILL qualification-supervisor.service")
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = failed", timeout=60)
          # The legacy flock is free, but the reserved journal still vetoes GC.
          machine.succeed("flock --exclusive --nonblock /nix/var/nix true")
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=false")
          machine.succeed("systemctl start qualification-supervisor.service; printf x > /run/qualification-before-roots")
          machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager | grep -F ROOTS_READY", timeout=60)
          info = json.loads(machine.succeed("cat ${state}/root-info.json"))
          assert len(info["roots"]["paths"]) == 2
          machine.succeed(f"test -e {info['unprotected']}; test ! -e {info['unbuilt']}")
          machine.succeed("build-executor-gate supervised-roots-check | grep -Fx retention_clear=false")
          machine.fail("build-executor-gate supervised-roots-release")
          # Deliberate native-GC exercise inside the admitted fixture aggregate,
          # AFTER publication. Not production ingress/GC-admission qualification.
          machine.succeed("systemctl start qualification-root-gc.service")
          machine.succeed(f"test ! -e {info['unprotected']}; test ! -e {info['unbuilt']}")
          for path in info["roots"]["paths"]:
              machine.succeed(f"test -e {path}")
          # Producer dies; neither process exit nor settled failure releases roots.
          machine.succeed(f"systemctl kill --kill-whom=main --signal=KILL {unit}")
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F recovering", timeout=60)
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = inactive", timeout=60)
          machine.succeed("build-executor-gate supervised-roots-check | grep -Fx retention_clear=false")
          # No consumer success claim: installed Retirement releases failed
          # input protection and the exact native gate under a new cleanup owner.
          installed_cleanup(machine)
          machine.fail("build-executor-gate supervised-roots-check")
          machine.log("INSTALLED_FAILED_RETIREMENT_PRECEDES_NEXT_GC_ADMISSION")
          hold_gc(machine)
          maintenance_unit = machine.succeed("build-executor-gate supervised-prepare collect").strip()
          ledger = json.loads(machine.succeed("cat ${state}/state.json"))["state"]
          assert ledger["version"] == 14
          intents = [job["request"] for job in ledger["jobs"] if job["request"]["kind"] == "maintenance"]
          collections = [intent for intent in intents if intent["request"]["operation"] == "collect_garbage"]
          assert len(collections) == 1
          assert "source" not in collections[0]["request"] and "selection" not in collections[0]["request"]
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=true")
          machine.succeed("systemctl start qualification-supervisor.service")
          collector_waiting(machine, maintenance_unit)
          machine.log("INSTALLED_MAINTENANCE_ADMITTED_EXCLUSIVE")
          # The fixed collector is unprivileged; upstream grants no separate
          # Maintenance-only operation mode. Same original daemon/UID boundary.
          daemon_pid = machine.succeed("systemctl show nix-daemon.service --property=MainPID --value").strip()
          native_args = base64.b64decode(machine.succeed(f"base64 -w0 /proc/{daemon_pid}/cmdline")).split(b"\0")
          assert native_args[1:-1] == expected_args
          machine.succeed("test $(stat -c %u:%a /nix/var/nix/daemon-socket/socket) = 1000:600")
          machine.log("UPSTREAM_MAINTENANCE_REUSES_EXCLUSIVE_UNTRUSTED_EXECUTOR")
          machine.fail("flock --shared --nonblock /nix/var/nix true")
          machine.succeed("systemctl kill --kill-whom=main --signal=KILL qualification-supervisor.service")
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = failed", timeout=60)
          machine.fail("flock --shared --nonblock /nix/var/nix true")
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=false")
          machine.succeed("systemctl start qualification-supervisor.service; printf x > /run/qualification-gc-lock-hold")
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F recovering", timeout=60)
          machine.succeed(f"journalctl -b -u {maintenance_unit} --no-pager -o cat | grep -Fx MAINTENANCE_COLLECTOR_EXITED")
          machine.succeed("flock --exclusive --nonblock /nix/var/nix true")
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=false")
          observed = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert observed["outcome"]["reason"]["kind"] == "verification_failed"
          for path in info["roots"]["paths"]:
              machine.succeed(f"test ! -e {path}")
          machine.succeed(f"test ! -e {info['unbuilt']}; systemctl is-active sshd.service")
          machine.fail("journalctl -b --no-pager | grep -F ROOTING_MUST_NOT_BUILD")
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = inactive", timeout=60)
          # Adversarial Git/copy fixture shares UID1000 with its synthetic native
          # evaluator. It is a counterexample, not installed source isolation.
          unit = machine.succeed("build-executor-gate supervised-prepare private-copy").strip()
          machine.succeed("systemctl start qualification-supervisor.service")
          machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx PRIVATE_COPY_FRESH_INODES_AND_UIDS", timeout=60)
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx PRIVATE_GIT_METADATA_PRESERVED_NO_GIT_IN_STORE")
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F recovering", timeout=60)
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = inactive", timeout=60)
          observed = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert observed["outcome"]["reason"]["kind"] == "verification_failed"
          private = json.loads(machine.succeed("cat ${state}/private-copy-fixture.json"))
          machine.succeed(f"runuser -u abird-owned-builder -- test -r {private['copy']}/.git/HEAD")
          machine.fail(f"runuser -u outsider -- cat {private['copy']}/.git/HEAD")
          machine.fail(f"runuser -u abird-owned-builder -- test -w {private['copy']}/payload")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx PRIVATE_SOURCE_DIAGNOSTIC_FD_CLOSED")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx PRIVATE_SOURCE_HELPERS_BOUNDED")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_BASE_TREE_OBJECTS_OBSERVED")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_BASE_INDEX_MATCHES_OBSERVED_TREE")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_FILTERED_BASE_BYTES_OBSERVED")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_SOURCE_RECIPE_MATCHES_JOURNAL_INTENT")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_SOURCE_RECIPE_REJECTS_WRONG_ARTIFACT")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_SOURCE_ADAPTER_BINARY_PATCH")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_LINKED_WORKTREE_NOT_SEALED")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_CHECKOUT_CONFIG_AND_METADATA_PRESERVED")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_STANDALONE_SOURCE_PARENT_INDEPENDENT")
          machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx NATIVE_INDEX_FLAGS_HIDE_EVALUATION_BYTES")
          for marker in [
              "UPSTREAM_DOT_ROOT_SOURCE_INFO_IS_CALLER_OUTPUT_NOT_PROVENANCE",
              "UPSTREAM_JSON_OUTPATH_ATTRSET_COERCION",
              "UPSTREAM_NATIVE_ADAPTER_ACCESSOR_BINDING_IGNORES_OUTPUT_SOURCE_INFO",
              "UPSTREAM_NATIVE_ADAPTER_JSON_PATH_PARITY",
              "UPSTREAM_OUTPUT_QUERY_NATIVE_PREFIX_ERROR_AND_RAW_PARITY",
              "NATIVE_OUTPUT_ABSENCE_NOT_EVALUATION_FAILURE",
          ]:
              machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx {marker}")
          # Corrupt locator cannot select release authority; only the journal can.
          machine.succeed("printf '%s' '{\"owner\": null}' > ${state}/private-copy-fixture.json")
          machine.succeed("build-executor-gate supervised-source-retain-nonempty | grep -Fx PRIVATE_SOURCE_NONEMPTY_RETAINED")
          machine.succeed(f"test -e {private['copy']}/payload")
          unit = machine.succeed("build-executor-gate supervised-prepare source-slot-empty").strip()
          machine.succeed("systemctl start qualification-supervisor.service")
          # Host-side ancestor flip: the hardened worker cannot write ancestors.
          ancestor = "${home}/.local/share/abird/abird-host-agent/owned-build"
          machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx PRIVATE_SOURCE_AWAITING_FOREIGN_ANCESTOR", timeout=60)
          machine.succeed(f"chown 1000 {ancestor}")
          machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx PRIVATE_SOURCE_FOREIGN_ANCESTOR_REJECTED", timeout=60)
          machine.succeed(f"chown 0 {ancestor}")
          machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx PRIVATE_SOURCE_EMPTY_BOUND", timeout=60)
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F recovering", timeout=60)
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = inactive", timeout=60)
          observed = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert observed["outcome"]["reason"]["kind"] == "verification_failed"
          before_wrong_release = machine.succeed("sha256sum ${state}/state.json")
          machine.fail("build-executor-gate supervised-source-retain-nonempty")
          assert before_wrong_release == machine.succeed("sha256sum ${state}/state.json")
          for _ in range(2):
              machine.succeed("build-executor-gate supervised-source-retire-empty | grep -Fx PRIVATE_SOURCE_EMPTY_RETIRED")
          # Native preparation executes only after admission, under the same
          # aggregate owner. These fixed inputs are not a source-verifier proof.
          for case in ["native-base", "native-overlay", "native-config", "native-partial", "native-fallback"]:
              unit = machine.succeed(f"build-executor-gate supervised-prepare {case}").strip()
              machine.succeed("systemctl start qualification-supervisor.service")
              if case == "native-partial":
                  marker = "NATIVE_PREPARATION_PARTIAL evaluated=1 failed=1"
              else:
                  count, skipped = (0, 1) if case == "native-overlay" else (2, 0)
                  marker = f"NATIVE_PREPARATION_READY case={case} evaluated={count} skipped={skipped}"
              machine.wait_until_succeeds(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx '{marker}'", timeout=90)
              if case == "native-base":
                  machine.succeed(f"journalctl -b -u {unit} --no-pager -o cat | grep -Fx SNAPSHOT_NAR_AND_AMBIENT_REJECTED")
              machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F recovering", timeout=60)
              machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = inactive", timeout=60)
              observed = json.loads(machine.succeed("build-executor-gate supervised-status"))
              expected = "client_failed" if case == "native-partial" else "verification_failed"
              assert observed["outcome"]["reason"]["kind"] == expected
              machine.fail("runuser -u abird-owned-builder -- cat ${state}/native-request")
          machine.fail("journalctl -b -u nix-daemon --no-pager | grep -F NATIVE_PREPARATION_MUST_NOT_BUILD")
          machine.succeed("systemctl is-active sshd.service")

      # Fresh authorities: never release/adopt an earlier maintenance reservation
      # merely to admit this fault experiment.
      def collector_death(machine):
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("sshd.service")
          installed_bootstrap(machine)
          hold_gc(machine)
          unit = machine.succeed("build-executor-gate supervised-prepare collect").strip()
          machine.succeed("systemctl start qualification-supervisor.service")
          collector_waiting(machine, unit)
          observe = "python3 /etc/qualification-gc-observe.py"
          worker = json.loads(machine.succeed(f"{observe} worker {shlex.quote(unit)}"))
          before = json.loads(machine.succeed("cat ${state}/state.json"))["state"]["jobs"]
          assert len(before) == 1 and before[0]["request"]["kind"] == "maintenance"
          machine.wait_until_succeeds(f"{observe} waiter {shlex.quote(unit)}", timeout=60)
          collector = json.loads(machine.succeed(f"{observe} waiter {shlex.quote(unit)}"))
          machine.log("NATIVE_COLLECTOR_WAITING_ON_GC_LOCK")
          # Controller loss first prevents an observer from racing away the
          # surviving-child evidence. No new deadline or second worker grant.
          machine.succeed("systemctl kill --kill-whom=main --signal=KILL qualification-supervisor.service")
          machine.wait_until_succeeds("systemctl is-failed qualification-supervisor.service", timeout=60)
          machine.fail("flock --shared --nonblock /nix/var/nix true")
          machine.succeed(f"{observe} kill-worker {shlex.quote(unit)} {shlex.quote(json.dumps(worker))}")
          machine.wait_until_succeeds(f"systemctl is-failed {shlex.quote(unit)}", timeout=60)
          machine.succeed(f"{observe} alive {shlex.quote(unit)} {shlex.quote(json.dumps(collector))}")
          assert json.loads(machine.succeed(f"{observe} waiter {shlex.quote(unit)}")) == collector
          machine.succeed("flock --exclusive --nonblock /nix/var/nix true")
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=false")
          machine.succeed("grep -Fx 'populated 1' /sys/fs/cgroup/abird.slice/abird-build.slice/cgroup.events")
          machine.log("NATIVE_COLLECTOR_SURVIVES_WORKER_AND_EXCLUSION_FD_LOSS")
          claim = json.loads(machine.succeed("cat ${state}/state.json"))["state"]["jobs"][0]["daemon_claim"]
          assert claim["handle"]["invocation_id"] == machine.succeed("systemctl show nix-daemon.service --property=InvocationID --value").strip()
          # Native connection workers explicitly outlive their daemon parent.
          # Re-activation must not exec another daemon for the unsettled owner.
          machine.succeed("systemctl kill --kill-whom=main --signal=KILL nix-daemon.service")
          machine.wait_until_succeeds("systemctl is-failed nix-daemon.service", timeout=60)
          machine.succeed(f"{observe} alive {shlex.quote(unit)} {shlex.quote(json.dumps(collector))}")
          machine.execute("systemctl start nix-daemon.service")
          machine.wait_until_succeeds("systemctl is-failed nix-daemon.service && journalctl -b -u nix-daemon.service --no-pager -o cat | grep -F 'daemon invocation already claimed'", timeout=60)
          assert machine.succeed("systemctl show nix-daemon.service --property=InvocationID --value").strip() != claim["handle"]["invocation_id"]
          assert json.loads(machine.succeed("cat ${state}/state.json"))["state"]["jobs"][0]["daemon_claim"] == claim
          assert json.loads(machine.succeed(f"{observe} waiter {shlex.quote(unit)}")) == collector
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=false")
          machine.log("DAEMON_REACTIVATION_REJECTED_WITH_ORIGINAL_COLLECTOR_ALIVE")
          machine.succeed("systemctl start qualification-supervisor.service")
          machine.wait_until_succeeds("build-executor-gate supervised-status | grep -F recovering", timeout=60)
          machine.wait_until_succeeds("test $(systemctl show qualification-supervisor.service --property=ActiveState --value) = inactive", timeout=60)
          observed = json.loads(machine.succeed("build-executor-gate supervised-status"))
          assert observed["outcome"]["reason"]["kind"] == "client_failed"
          after = json.loads(machine.succeed("cat ${state}/state.json"))["state"]["jobs"]
          assert len(after) == 1 and after[0]["request"] == before[0]["request"]
          assert after[0]["reserved_at"] == before[0]["reserved_at"]
          machine.succeed(f"{observe} gone {shlex.quote(unit)} {shlex.quote(json.dumps(collector))}")
          machine.succeed("test ! -d /sys/fs/cgroup/abird.slice/abird-build.slice || grep -Fx 'populated 0' /sys/fs/cgroup/abird.slice/abird-build.slice/cgroup.events")
          machine.succeed("build-executor-gate supervised-retention-check | grep -Fx serialized_retention_clear=false")
          machine.fail(f"journalctl -b -u {shlex.quote(unit)} --no-pager -o cat | grep -Fx MAINTENANCE_COLLECTOR_EXITED")
          machine.log("NATIVE_COLLECTOR_DEATH_SETTLED_WITHOUT_REPLAY_OR_RELEASE")
          machine.succeed("systemctl stop qualification-gc-lock.service && systemctl is-active sshd.service")

      # Independent guests continue after a failed scenario, never after a failed
      # guest shutdown. All failures remain fatal to the combined check.
      failures = []
      for machine, scenario in [
          (classic, launch_interlock),
          (delegated, launch_interlock),
          (supervisedClassic, supervised_lifecycle),
          (supervisedDelegated, supervised_lifecycle),
          (protectedClassic, protection_and_sources),
          (protectedDelegated, protection_and_sources),
          (collectorDeathClassic, collector_death),
          (collectorDeathDelegated, collector_death),
      ]:
          try:
              scenario(machine)
          except Exception:
              failures.append(machine.name)
              machine.log("QUALIFICATION_FAILED: " + machine.name)
              traceback.print_exc()
          else:
              machine.log("QUALIFICATION_PASSED: " + machine.name)
          finally:
              machine.shutdown()
      assert not failures, "Failed VM scenarios: " + ", ".join(failures)
    '';
  }
