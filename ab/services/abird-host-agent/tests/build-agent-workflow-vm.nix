# Installed co-located and three-node workflows through the public entries.
# A: submit → caller loss → `fleet owned attach` to the same attempt → cancel
#    → positive settlement → caller retirement → next admission.
# B: one realization → signed publication (Harmonia) → co-located consumer
#    verification and direct roots → ACK → release → retirement; then dry and
#    real retained Deploys to a second node, and a failing one rolled back.
# Remote: caller-only capture → builder → signed separate-store copyback,
# original source contexts, acquisition recovery and target deployment cancel.
# The target generations are NixOS specialisations of the target node. The
# fixture flake names their host-evaluated derivations (no in-VM NixOS eval);
# their closures are pre-registered and signed in the builder store, so the
# owned realization is a validity check, not a rebuild.
{pkgs}: let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  home = "/home/operator";
  repo = "${home}/repo";
  remoteHome = "/home/remote-operator";
  remoteRepo = "${remoteHome}/repo";
  thinHome = "/home/ci-operator";
  # Disposable, test-only signing pair generated for this VM fixture; not a
  # credential and never trusted outside it. Typed settings only: the
  # executor forbids include/directive text in its immutable Nix context.
  signing = {
    secret = pkgs.writeText "owned-workflow-test-signing.sec" "owned-workflow-test-1:cHW3rIUmhGT6Sqq3qm8Md4o+dBQUOWnohhEUHyQiR4FG+hfe9dzt+sYw4AHrYLO/2KyPwu+wuUFhh9joQ1IdbA==";
    public = "owned-workflow-test-1:RvoX3vXc7frGMOAB62Czv9isj8LvsLlBYYfY6ENSHWw=";
  };
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  # Compile the existing libtest entry reproducibly; explicit root execution
  # below is the namespace gate. An ignored Cargo test is not acceptance.
  namespaceProbe = pkgs.abird-host-agent.checks.test.overrideAttrs (old: {
    name = "owned-offline-namespace-probe";
    doCheck = false;
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.jq];
    buildPhase = ''
      runHook preBuild
      cargoWithProfile test --offline --lib --no-run --message-format=json \
        -p abird-host-agent > namespace-artifacts.json
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      executable=$(jq -ser '
        map(select(.reason == "compiler-artifact" and .target.name == "abird_host_agent"
          and .target.kind == ["lib"] and .profile.test and .executable != null))
        | if length == 1 then .[0].executable else error("expected one namespace test executable") end
      ' namespace-artifacts.json)
      mkdir -p "$out/bin"
      install -m 0755 "$executable" "$out/bin/owned-offline-namespace-probe"
      runHook postInstall
    '';
  });
  # VM-only callbacks; both roles explicitly declare this helper/Python runtime.
  # Merely installing a package does not grant all ambient system PATH reads.
  offlineFixture =
    pkgs.runCommand "owned-offline-vm-fixture" {
      meta = {
        description = "Installed offline Git helper qualification fixture";
        mainProgram = "owned-offline-fixture";
      };
    } ''
      mkdir -p "$out/bin"
      printf '#!${pkgs.python3}/bin/python3 -I\n' > "$out/bin/owned-offline-helper"
      cat ${./fixtures/owned-offline-helper.py} >> "$out/bin/owned-offline-helper"
      printf '#!${pkgs.python3}/bin/python3 -I\n' > "$out/bin/owned-offline-fixture"
      cat ${./fixtures/owned-offline-fixture.py} >> "$out/bin/owned-offline-fixture"
      chmod 0755 "$out/bin/owned-offline-helper" "$out/bin/owned-offline-fixture"
    '';
  # Pure evaluation: ordinary/slow builds use the sandbox shell. Pressure uses
  # the preinstalled Python closure; one prefaulted mapping must exceed the cap.
  # @APP_DRV@/@APP_OUT@ name one host-evaluated NixOS generation.
  flake = pkgs.writeText "workflow-flake.nix" ''
    {
      outputs = _: let
        plan = name: builtins.derivation {
          inherit name;
          system = ${builtins.toJSON system};
          builder = "/bin/sh";
          args = [ "-c" "echo built-''${name} > $out" ];
        };
        slow = builtins.derivation {
          name = "owned-workflow-slow";
          system = ${builtins.toJSON system};
          builder = "/bin/sh";
          args = [ "-c" "echo owned-slow-marker >/dev/null; while :; do :; done" ];
        };
        pressure = builtins.derivation {
          name = "owned-workflow-pressure";
          system = ${builtins.toJSON system};
          builder = builtins.appendContext "${pkgs.python3}/bin/python3" {
            "${pkgs.python3}" = { path = true; };
          };
          args = [ "-I" "-c" "import mmap; allocation = mmap.mmap(-1, 1024 * 1024 * 1024, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS | mmap.MAP_POPULATE, prot=mmap.PROT_READ | mmap.PROT_WRITE)" ];
        };
        host = toplevel: { config = { system.build.toplevel = toplevel; boot.isContainer = false; }; };
      in {
        nixbot.deployDependencies = {};
        nixosConfigurations = {
          artifact = host (plan "owned-workflow-artifact");
          dependency = host (plan "owned-workflow-dependency");
          recover = host (plan "owned-workflow-recovery");
          discard = host (plan "owned-workflow-discard");
          slow = host slow;
          pressure = host pressure;
          app = host { type = "derivation"; drvPath = "@APP_DRV@"; outPath = "@APP_OUT@"; };
        };
      };
    }
  '';
  inventoryText = callerHome: builderTarget: ''
    {
      config.buildCache = { url = "http://builder:5000"; host = "builder"; };
      hosts = {
        builder = { target = "${builderTarget}"; user = "operator"; deploy = "skip"; };
        artifact = { target = "127.0.0.3"; user = "operator"; deploy = "skip"; };
        dependency = { target = "127.0.0.6"; user = "operator"; deploy = "skip"; };
        recover = { target = "127.0.0.7"; user = "operator"; deploy = "skip"; };
        discard = { target = "127.0.0.8"; user = "operator"; deploy = "skip"; };
        slow = { target = "127.0.0.4"; user = "operator"; deploy = "skip"; };
        pressure = { target = "127.0.0.5"; user = "operator"; deploy = "skip"; };
        app = {
          target = "app";
          user = "operator";
          identityKey = "${callerHome}/.ssh/id_ed25519";
          knownHosts = "app ${keys.snakeOilEd25519PublicKey}";
        };
      };
    }
  '';
  inventory = pkgs.writeText "workflow-inventory.nix" (inventoryText home "127.0.0.1");
  remoteInventory = pkgs.writeText "remote-workflow-inventory.nix" (inventoryText remoteHome "builder");
  remoteRouting = {
    hosts = {
      operator = {
        target = "127.0.0.1";
        user = "operator";
      };
      builder = {
        target = "builder";
        user = "operator";
        identityKey = "${remoteHome}/.ssh/id_ed25519";
      };
    };
    config = {
      controller = "operator";
      transferBroker = "operator";
      builders = ["builder"];
      registries.nix = {
        host = "builder";
        url = "http://builder:5000";
      };
    };
  };
  localRouting = {
    hosts.builder = {
      target = "127.0.0.1";
      user = "operator";
    };
    config = {};
  };
in
  pkgs.testers.runNixOSTest {
    name = "build-agent-workflow";
    # Target: a plain NixOS host; candidate generations are its specialisations.
    nodes = {
      app = {pkgs, ...}: {
        services.openssh.enable = true;
        users.users.operator = {
          isNormalUser = true;
          uid = 1100;
          extraGroups = ["wheel"];
          openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
        };
        security.sudo.wheelNeedsPassword = false;
        # Fleet targets run `nix copy` for cache pulls (nix-command, as fleet hosts).
        nix.settings = {
          experimental-features = ["nix-command"];
          trusted-public-keys = [signing.public];
        };
        specialisation = {
          next.configuration.environment.etc."owned-deploy-marker".text = "next";
          blocked.configuration = {
            environment.etc."owned-deploy-marker".text = "blocked";
            system.activationScripts.owned-forward-boundary = {
              deps = ["specialfs"];
              text = ''
                if [ -p /run/owned-activation-gate ]; then
                  : >/run/owned-activation-entered
                  read -r _owned_gate </run/owned-activation-gate
                fi
              '';
            };
          };
          broken.configuration = {
            environment.etc."owned-deploy-marker".text = "broken";
            systemd.services.owned-broken = {
              wantedBy = ["multi-user.target"];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${pkgs.coreutils}/bin/false";
              };
            };
          };
        };
        virtualisation.memorySize = 1024;
        system.stateVersion = "26.05";
      };
      operator = {pkgs, ...}: {
        imports = [../. ../../abird-host-manager];
        # The offline boundary requires Landlock ABI9; default 6.18 lacks it.
        boot.kernelPackages = pkgs.linuxPackages_latest;
        services.abird-host-manager.buildController = {
          enable = true;
          inventory = remoteRouting;
          callers.operator = {
            repositoryId = "fixture";
            sourceRoots = [remoteRepo "${remoteHome}/inventory"];
            nix.substitute = false;
          };
          capture = {
            relayUser = "owned-source-relay";
            relayKeyFile = "/run/keys/owned-capture-relay";
            runtimePackages = [offlineFixture pkgs.python3];
            memoryMax = 536870912;
            tasksMax = 128;
            cpuPercent = 100;
            maxSeconds = 600;
            sourceLimits = {
              entries = 32768;
              bytes = 67108864;
              depth = 64;
            };
          };
        };
        users = {
          groups.operator.gid = 2700;
          users = {
            operator = {
              isNormalUser = true;
              uid = 2700;
              group = "operator";
              home = remoteHome;
            };
            ci-operator = {
              isNormalUser = true;
              uid = 2701;
              home = thinHome;
            };
          };
        };
        nix.settings = {
          experimental-features = ["nix-command" "flakes"];
          substituters = lib.mkForce [];
          trusted-public-keys = [signing.public];
        };
        environment = {
          systemPackages = [pkgs.git pkgs.curl pkgs.python3 pkgs.nixbot offlineFixture];
          etc."ssh/ssh_known_hosts".text = "builder ${keys.snakeOilEd25519PublicKey}\napp ${keys.snakeOilEd25519PublicKey}\n";
        };
        systemd.services."abird-owned-capture@".serviceConfig.StandardError = lib.mkForce "journal";
        virtualisation = {
          cores = 2;
          memorySize = 1536;
          useNixStoreImage = true;
          writableStore = true;
        };
        system.stateVersion = "26.05";
      };
      builder = {
        nodes,
        pkgs,
        ...
      }: {
        imports = [../. ../../abird-host-manager];
        networking.hostName = "builder";
        boot.kernelPackages = pkgs.linuxPackages_latest;
        # Expected cgroup OOM must kill its worker, not the test VM. Global OOM still panics.
        boot.kernel.sysctl."vm.panic_on_oom" = 1;
        services = {
          abird-host-agent.buildExecutor = {
            enable = true;
            acceptSubmissions = true;
            identity = {
              authority_id = "workflow";
              builder_id = "builder";
              store_id = "shared-store";
            };
            sourceUid = 1001;
            readerUid = 1000;
            readerGid = 1000;
            controlGid = 1002;
            principals.operator = {};
            inputPrincipals.owned-source-relay.issuer = "operator";
            inputPort = 2022;
            runtimePackages = [offlineFixture pkgs.python3];
            repositories.fixture = "file:///var/lib/workflow-ci.git";
            gitConfiguration = pkgs.writeText "workflow-git-config" "[safe]\n\tdirectory = *\n";
            resources = {
              cpu_quota_micros = 100000;
              cpu_period_micros = 100000;
              memory_high = 536870912;
              # Stricter hard cap: exercise OOM before high-limit throttling times out.
              memory_max = 603979776;
              swap_max = 0;
              tasks_max = 256;
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
              bytes = 67108864;
              depth = 64;
            };
            # Foreground renewal rides on the caller's poll pass (status, renew,
            # events, inputs; one unshared SSH session each, ~1-1.5 s in this
            # VM, + 1 s park): stale must span several passes. 6 s expired a
            # lease before worker start. Test input, not defaults.
            deadlines = {
              heartbeat_seconds = 5;
              stale_seconds = 20;
              owner_seconds = 60;
              queue_seconds = 120;
              runtime_seconds = 600;
              stop_grace_seconds = 8;
              stop_limit_seconds = 30;
              retention_seconds = 600;
            };
            maxJobs = 1;
            maxCores = 1;
            submissionAgeSeconds = 120;
            futureSkewSeconds = 2;
            replaySeconds = 600;
            controlTimeoutMillis = 5000;
            maxConnections = 4;
            connectionLifetimeSeconds = 30;
          };
          abird-host-manager.buildController = {
            enable = true;
            inventory = localRouting;
            callers.operator = {
              repositoryId = "fixture";
              sourceRoots = [repo];
              nix.substitute = false;
            };
          };
          # Signed publisher: reads the store database, not the daemon socket.
          harmonia.cache = {
            enable = true;
            signKeyPaths = ["${signing.secret}"];
            settings.bind = "0.0.0.0:5000";
          };
        };
        nix.settings = {
          experimental-features = ["nix-command" "flakes"];
          substituters = lib.mkForce [];
          max-jobs = 1;
          cores = 1;
          min-free = 0;
          secret-key-files = ["${signing.secret}"];
          extra-trusted-public-keys = [signing.public];
        };
        # Disposable VM only: surface executor diagnostics (production discards).
        systemd.services = {
          abird-owned-build-supervisor.serviceConfig.StandardError = lib.mkForce "journal";
          "abird-build-client@".serviceConfig.StandardError = lib.mkForce "journal";
        };
        networking.firewall.allowedTCPPorts = [5000];
        services.openssh.enable = true;
        users.users = {
          operator = {
            isNormalUser = true;
            uid = 1100;
            openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
          };
          owned-source-relay = {
            isNormalUser = true;
            uid = 1201;
            # Invalid password, not a locked account: admitted sshd uses no PAM.
            hashedPassword = "*";
            openssh.authorizedKeys.keys = [keys.snakeOilPublicKey];
          };
        };
        # ldd inventories the privileged test ELF's exact runtime; it is not an
        # ambient runtime grant for captured caller helpers.
        environment.systemPackages = [pkgs.git pkgs.curl pkgs.python3 pkgs.glibc.bin offlineFixture];
        virtualisation = {
          cores = 2;
          memorySize = 2048;
          useNixStoreImage = true;
          writableStore = true;
          # Host-evaluated candidate generations: derivation files and outputs.
          additionalPaths =
            [namespaceProbe]
            ++ lib.concatMap (name: let
              toplevel = nodes.app.specialisation.${name}.configuration.system.build.toplevel;
            in [toplevel toplevel.drvPath]) ["next" "broken" "blocked"];
        };
        system.stateVersion = "26.05";
      };
    };
    testScript = {nodes, ...}: let
      generation = name: let
        toplevel = nodes.app.specialisation.${name}.configuration.system.build.toplevel;
      in {
        drv = builtins.unsafeDiscardStringContext toplevel.drvPath;
        out = builtins.unsafeDiscardStringContext "${toplevel}";
      };
      next = generation "next";
      broken = generation "broken";
      blocked = generation "blocked";
    in ''
      import json, shlex

      start_all()
      builder.wait_for_unit("multi-user.target")
      app.wait_for_unit("multi-user.target")
      operator.wait_for_unit("multi-user.target")
      builder.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /etc/ssh/ssh_host_ed25519_key && systemctl restart sshd")
      builder.wait_for_unit("sshd.service")
      operator.wait_for_unit("abird-owned-capture-control.socket")
      operator.succeed("install -D -m 0600 ${keys.snakeOilPrivateKey} /run/keys/owned-capture-relay")
      operator.succeed("install -d -m 0700 -o operator ${remoteHome}/.ssh && install -m 0600 -o operator ${keys.snakeOilEd25519PrivateKey} ${remoteHome}/.ssh/id_ed25519")
      # The root relay has only the forced input endpoint, never arbitrary SSH
      # execution/control; an ordinary caller cannot authenticate as that role.
      operator.fail("ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -i /run/keys/owned-capture-relay owned-source-relay@builder 'touch /tmp/owned-relay-escaped' </dev/null")
      builder.fail("test -e /tmp/owned-relay-escaped")
      operator.fail("ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -i ${remoteHome}/.ssh/id_ed25519 owned-source-relay@builder true </dev/null")
      app.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /etc/ssh/ssh_host_ed25519_key && systemctl restart sshd")
      app.wait_for_unit("sshd.service")
      booted = app.succeed("readlink -f /run/current-system").strip()

      # Pre-registered host-evaluated closures, signed as this builder would
      # sign its own realizations (the owned build then only validates them).
      builder.succeed("nix store sign --key-file ${signing.secret} --recursive ${next.out} ${broken.out} ${blocked.out}")
      builder.succeed("install -d -m 0700 -o operator ${home}/.ssh && install -m 0600 -o operator ${keys.snakeOilEd25519PrivateKey} ${home}/.ssh/id_ed25519")

      git = "git -c user.email=operator@example -c user.name=operator -c commit.gpgsign=false"
      builder.succeed(
          "runuser -u operator -- sh -c " + shlex.quote(
              "printf '[user]\\n\\tname = operator\\n\\temail = operator@example\\n' > ${home}/.gitconfig && chmod 0600 ${home}/.gitconfig && "
              f"mkdir -p ${repo}/hosts && cd ${repo} && git init -q && "
              f"sed -e 's|@APP_DRV@|${next.drv}|' -e 's|@APP_OUT@|${next.out}|' ${flake} > flake.nix && "
              f"cp ${inventory} hosts/nixbot.nix && chmod u+w hosts/nixbot.nix && "
              f"git add -A && {git} commit -qm fixture"
          )
      )

      operator.succeed(
          "runuser -u operator -- sh -c " + shlex.quote(
              "printf '[user]\\n\\tname = operator\\n\\temail = operator@example\\n' > ${remoteHome}/.gitconfig && chmod 0600 ${remoteHome}/.gitconfig && "
              f"mkdir -p ${remoteRepo}/hosts ${remoteHome}/inventory && cd ${remoteRepo} && git init -q && "
              f"sed -e 's|@APP_DRV@|${next.drv}|' -e 's|@APP_OUT@|${next.out}|' -e 's|owned-workflow-|owned-remote-|g' ${flake} > flake.nix && "
              f"cp ${remoteInventory} hosts/nixbot.nix && chmod u+w hosts/nixbot.nix && "
              "printf 'owned-offline-probe.txt filter=owned-offline\\n' > .gitattributes && "
              "printf 'owned offline probe\\n' > owned-offline-probe.txt && "
              f"git add -A && {git} commit -qm remote-fixture"
          )
      )
      builder.fail("test -e ${remoteHome}")
      operator.fail("systemctl cat abird-owned-build-supervisor.service")
      operator.succeed("systemctl is-active nix-daemon.socket")
      for machine in [builder, operator]:
          machine.succeed("python3 -c 'import ctypes; abi = ctypes.CDLL(None).syscall(444, 0, 0, 1); assert abi >= 9, abi'")

      # Configured CI repository: independent of the receiving account checkout.
      builder.succeed("git -c safe.directory=\'*\' clone --bare --no-hardlinks ${repo} /var/lib/workflow-ci.git")
      ci_sha = builder.succeed("git --git-dir=/var/lib/workflow-ci.git rev-parse HEAD").strip()

      # Explicit installed bootstrap, then the real supervisor (OnSuccess).
      builder.succeed("systemctl start abird-owned-build-bootstrap.service")
      builder.wait_for_unit("abird-owned-build-supervisor.service")
      builder.succeed("systemd-run --quiet --wait --pipe --collect --unit=owned-namespace-probe --slice=abird-build.slice --setenv=PATH=/run/current-system/sw/bin ${namespaceProbe}/bin/owned-offline-namespace-probe --exact build_executor::process::offline::tests::namespace::production_capture_entry_drops_inherited_authority_and_hides_host_proc --ignored --nocapture")
      builder.log("OFFLINE_PRIVILEGED_PRODUCTION_ENTRY_QUALIFIED")

      builder.succeed("""cat > /run/workflow-fleet.sh <<'EOF'
      #!/bin/sh
      # Caller with a minimal, credential-free environment; never a root caller.
      # Explicit Git profile from /run/workflow-git-profile, else Git defaults.
      profile=$(cat /run/workflow-git-profile 2>/dev/null)
      ${pkgs.util-linux}/bin/runuser -u operator -- ${pkgs.coreutils}/bin/env -i HOME=${home} USER=operator LOGNAME=operator $profile \\
        PATH=/run/current-system/sw/bin /run/current-system/sw/bin/sh -c 'cd ${repo} && exec abird-host-manager fleet "$@"' fleet "$@" \\
        > /run/fleet.out 2> /run/fleet.err
      echo $? > /run/fleet.code
      EOF
      chmod 0755 /run/workflow-fleet.sh""")

      remote_script = builder.succeed("cat /run/workflow-fleet.sh").replace("${home}", "${remoteHome}")
      operator.succeed("printf %s " + shlex.quote(remote_script) + " > /run/workflow-fleet.sh && chmod 0755 /run/workflow-fleet.sh")

      def start(arguments, caller=builder):
          caller.succeed("rm -f /run/fleet.code /run/fleet.out /run/fleet.err")
          caller.succeed(f"systemd-run --unit=workflow-fleet --collect --no-block /run/workflow-fleet.sh {arguments}")

      def finish(arguments, expect=0, caller=builder):
          # Fail fast on executor loss instead of waiting out the caller.
          condition = "test -e /run/fleet.code"
          if caller == builder:
              condition += " || ! systemctl is-active -q abird-owned-build-supervisor"
          try:
              caller.wait_until_succeeds(condition, timeout=900)
          except Exception:
              builder.log("workflow wait ended without completion; collecting existing diagnostics")
          finished = caller.execute("test -e /run/fleet.code")[0] == 0
          code = int(caller.succeed("cat /run/fleet.code").strip()) if finished else -1
          output = caller.succeed("cat /run/fleet.out || true")
          error = caller.succeed("cat /run/fleet.err || true")
          caller.execute("systemctl stop workflow-fleet")
          matched = finished and (code != 0 if expect == "fail" else code == expect)
          if not matched:
              builder.log(output[-4000:])
              builder.log(error[-6000:])
              if caller != builder:
                  caller.log(caller.succeed("journalctl -b -u 'abird-owned-capture@*' -u 'abird-owned-capture-control@*' -u abird-owned-capture-reap -u nix-daemon --no-pager -o cat | tail -n 120"))
              builder.log(builder.succeed("journalctl -b -u 'abird-build-client@*' -u abird-owned-build-supervisor -u nix-daemon -u harmonia --no-pager -o cat | tail -n 200"))
              builder.log(builder.succeed("for f in $(find /var/tmp/nixbot -type f 2>/dev/null | sort); do echo \"== $f\"; tail -n 30 \"$f\"; done"))
          assert matched, f"fleet {arguments} exited {code}, expected {expect}"
          assert "--strategy=agent is experimental" in error
          # Handoff records only; per-poll status objects carry no "state".
          records = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
          return [record for record in records if "state" in record], error

      def fleet(arguments, expect=0, caller=builder):
          start(arguments, caller)
          return finish(arguments, expect, caller)

      def owned(arguments, caller=builder):
          # Same frontend, durable-run verbs (manager `fleet owned`).
          caller_home = "${home}" if caller == builder else "${remoteHome}"
          return caller.execute(
              f"runuser -u operator -- env -i HOME={caller_home} PATH=/run/current-system/sw/bin "
              f"abird-host-manager fleet owned {arguments}"
          )

      def journal():
          return json.loads(builder.succeed("cat /var/lib/abird/abird-host-agent/owned-build/state.json"))["state"]

      def run_gone(run, caller=builder):
          caller_home = "${home}" if caller == builder else "${remoteHome}"
          uid = "1100" if caller == builder else "2700"
          caller.fail(f"test -e {caller_home}/.local/state/abird/abird-host-manager/fleet-owned/{run}")
          caller.fail(f"test -e /nix/var/nix/gcroots/abird-owned-fleet/{uid}/{run}")

      def check_handoff(lines, host, retired=True, caller=builder):
          states = [line["state"] for line in lines]
          assert states == ["recorded", "consumed"] + (["retired"] if retired else []), states
          (outputs,) = lines[1]["outputs"].values()
          path = outputs[host]["out"]
          # Signed publication of exactly that output.
          narinfo = builder.succeed(f"curl -fsS http://builder:5000/$(basename {path} | cut -d- -f1).narinfo")
          assert "Sig: owned-workflow-test-1:" in narinfo, narinfo
          if retired:
              run_gone(lines[0]["run_id"], caller)
          return path

      builder_idle = (
          "import json; s=json.load(open('/var/lib/abird/abird-host-agent/owned-build/state.json'))['state']; "
          "assert s['pool']['owner'] is None, s['pool']; "
          "builds=[j for j in s['jobs'] if j['request']['kind']=='build']; "
          "assert builds and all(j.get('retirement') and j['retirement']['complete'] for j in builds), builds"
      )

      # Forwarded CI contract, through the real receiving manager: ordinary
      # operator SHA/patch preparation, then admitted configured-repo execution.
      # No local caller/capture profile: ordinary Git/SSH only, same forced entry.
      operator.fail("test -e /etc/abird-owned-fleet/2701.json")
      operator.succeed("python3 -c 'import json; p=json.load(open(\"/etc/abird-owned-capture.json\")); assert \"2701\" not in p[\"callers\"]'")
      operator.succeed("install -d -m 0700 -o ci-operator ${thinHome}/.ssh && install -m 0600 -o ci-operator ${keys.snakeOilEd25519PrivateKey} ${thinHome}/.ssh/id_ed25519")
      operator.succeed('runuser -u ci-operator -- ssh-keygen -q -t ed25519 -N "" -f ${thinHome}/.ssh/ci')
      ci_key = operator.succeed("cat ${thinHome}/.ssh/ci.pub").strip()
      ci_authorization = 'restrict,command="${pkgs.nixbot}/bin/nixbot" ' + ci_key
      builder.succeed("printf '%s\\n' " + shlex.quote(ci_authorization) + " >> ${home}/.ssh/authorized_keys && chown operator ${home}/.ssh/authorized_keys && chmod 0600 ${home}/.ssh/authorized_keys")
      operator.succeed("runuser -u ci-operator -- sh -c " + shlex.quote(
          "git clone -q operator@builder:${repo} ${thinHome}/ci && cd ${thinHome}/ci && "
          "sed -i s/owned-workflow-dependency/owned-ci-patched/g flake.nix && git add flake.nix"
      ))
      ci_script = remote_script.replace("${remoteHome}", "${thinHome}").replace("${thinHome}/repo", "${thinHome}/ci")
      ci_script = ci_script.replace("runuser -u operator", "runuser -u ci-operator").replace("USER=operator LOGNAME=operator", "USER=ci-operator LOGNAME=ci-operator")
      operator.succeed("printf %s " + shlex.quote(ci_script) + " > /run/workflow-fleet.sh")
      ci_host = operator.succeed("getent ahostsv4 builder | awk 'NR == 1 {print $1}'").strip()
      ci_trust = shlex.quote(f"{ci_host} ${keys.snakeOilEd25519PublicKey}")
      lines, _ = fleet(f"build --strategy=agent --ci-trigger --ci-host {ci_host} --ci-user operator --ci-check-ssh-key-path ${thinHome}/.ssh/ci --ci-known-hosts {ci_trust} --host dependency --dirty-staged --sha {ci_sha}", caller=operator)
      operator.succeed("printf %s " + shlex.quote(remote_script) + " > /run/workflow-fleet.sh")
      ci_path = check_handoff(lines, "dependency")
      assert builder.succeed(f"cat {ci_path}").strip() == "built-owned-ci-patched"
      ci_attempts = set(lines[0]["attempts"])
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)
      builder.log("WORKFLOW_CI_CONFIGURED_SHA_SIGNED_HANDOFF")
      operator.fail("test -e ${thinHome}/.local/state/abird/abird-host-manager/fleet-owned")
      builder.log("WORKFLOW_CI_UNPROVISIONED_CALLER_SIGNED_HANDOFF")

      # Workflow A through the manager frontend; explicit caller Git profile.
      builder.succeed("echo GIT_CONFIG_GLOBAL=${home}/.gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 > /run/workflow-git-profile")
      start("build --strategy=agent --host slow")
      try:
          builder.wait_until_succeeds("pgrep -f 'owned-slow-marke[r]' || test -e /run/fleet.code", timeout=600)
          builder.succeed("pgrep -f 'owned-slow-marke[r]'")
      except Exception:
          builder.log(builder.execute("tail -c 6000 /run/fleet.err")[1])
          builder.log(builder.execute("journalctl -b -u 'abird-build-client@*' -u abird-owned-build-supervisor -u nix-daemon --no-pager -o cat -n 100")[1])
          for job in journal()["jobs"]:
              builder.log(json.dumps({"attempt": job["attempt"], "stop": job["stop"], "source_allocated": job["private_source"] is not None, "native_started": job["native_phase"] is not None, "daemon_claimed": job["daemon_claim"] is not None}))
          builder.log(builder.succeed("python3 -c \"import glob,json; fields=['submit_claimed','input_ready','capture_claimed','input_claimed','input_received','event_cursor']; [print(json.dumps({k:c.get(k) for k in fields})) for p in glob.glob('${home}/.local/state/abird/abird-host-manager/fleet-owned/*/manifest.json') for c in json.load(open(p))['manifest']['children'].values()]\""))
          builder.log(builder.succeed("ps -eo pid,ppid,uid,stat,wchan:24,comm"))
          raise
      run = json.loads(builder.succeed("head -n1 /run/fleet.out"))["run_id"]
      (attempt,) = json.loads(builder.succeed("head -n1 /run/fleet.out"))["attempts"]
      builder.succeed("systemctl kill --signal=KILL workflow-fleet")  # caller lost
      builder.wait_until_fails("systemctl is-active -q workflow-fleet", timeout=30)
      code, observed = owned(f"attach {run} --wait-seconds 5")
      assert code != 0 and attempt in observed, observed  # observed, not settled
      builds = [j for j in journal()["jobs"] if j["request"]["kind"] == "build"]
      assert [j["acceptance"]["attempt_id"] for j in builds if j["acceptance"]["attempt_id"] not in ci_attempts] == [attempt], builds
      builder.succeed("pgrep -f 'owned-slow-marke[r]'")  # same execution, no replay
      # Effective kernel limits and actual Nix ancestry while the work CPU is
      # saturated. Control/renew/reconnect above must remain outside that group.
      work_group = "/sys/fs/cgroup/abird.slice/abird-build.slice"
      for field, value in [("cpu.max", "100000 100000"), ("memory.high", "536870912"), ("memory.max", "603979776"), ("memory.swap.max", "0"), ("pids.max", "256")]:
          assert builder.succeed(f"cat {work_group}/{field}").strip() == value, field
      for unit in ["abird-owned-build-supervisor.service", "abird-owned-build-control.socket"]:
          builder.succeed(f"systemctl is-active {unit}")
      supervisor_group = builder.succeed("systemctl show -p ControlGroup --value abird-owned-build-supervisor.service").strip()
      assert supervisor_group.startswith("/abird.slice/abird-control.slice/"), supervisor_group
      publisher_group = builder.succeed("systemctl show -p ControlGroup --value harmonia.service").strip()
      assert publisher_group.startswith("/abird.slice/abird-build.slice/"), publisher_group
      assert "/abird-build-owned.slice/" not in publisher_group, publisher_group
      daemon_group = builder.succeed("systemctl show -p ControlGroup --value nix-daemon.service").strip()
      assert daemon_group.startswith("/abird.slice/abird-build.slice/abird-build-owned.slice/"), daemon_group
      workers = builder.succeed("ps -eo pid,user | awk '$2 ~ /^nixbld/ {print $1}'").split()
      assert workers
      for pid in workers:
          assert builder.succeed(f"cat /proc/{pid}/cgroup").strip().startswith("0::/abird.slice/abird-build.slice/")
      builder.log("WORKFLOW_A_RECONNECTED_TO_SAME_ATTEMPT")
      code, observed = owned(f"cancel {run} --wait-seconds 120")
      assert code == 0, observed
      job = next(j for j in journal()["jobs"] if j["acceptance"]["attempt_id"] == attempt)
      assert job["settled_at"] is not None and job["attempt"]["state"]["outcome"] == {"kind": "cancelled", "reason": {"kind": "cancelled"}}, job["attempt"]
      builder.fail("pgrep -f 'owned-slow-marke[r]'")
      builder.log("WORKFLOW_A_CANCELLED_AFTER_POSITIVE_SETTLEMENT")
      code, observed = owned(f"retire {run}")
      assert code == 0, observed
      run_gone(run)
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Workflow B (also Workflow A's next admission); from here the caller
      # sets no Git variables: discovered default profile (~/.gitconfig).
      builder.succeed("rm /run/workflow-git-profile")
      builder.fail("test -e /etc/gitconfig")
      lines, _ = fleet("build --strategy=agent --host artifact")
      path = check_handoff(lines, "artifact")
      assert builder.succeed(f"cat {path}").strip() == "built-owned-workflow-artifact"
      builder.log("WORKFLOW_B_BUILD_SIGNED_CONSUMED_ACKED_RELEASED_RETIRED")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)
      builder.log("WORKFLOW_B_BUILDER_RETIREMENT_COMPLETE_POOL_IDLE")

      # Dry retained Deploy: ordinary phases, target untouched.
      lines, error = fleet("deploy --strategy=agent --host app --dry")
      assert check_handoff(lines, "app") == "${next.out}"
      for phase in ["Build systems", "Snapshot generations", "Acquire deployment artifacts", "Deploy systems", "Verify deployment health"]:
          assert phase in error, phase
      assert app.succeed("readlink -f /run/current-system").strip() == booted
      builder.log("WORKFLOW_B_DRY_DEPLOY_RETAINED_HANDOFF")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Real retained Deploy: existing target-local activation authority.
      lines, error = fleet("deploy --strategy=agent --host app")
      assert check_handoff(lines, "app") == "${next.out}"
      assert app.succeed("readlink -f /run/current-system").strip() == "${next.out}"
      assert app.succeed("cat /etc/owned-deploy-marker").strip() == "next"
      builder.log("WORKFLOW_B_REAL_DEPLOY_ACTIVATED_RETAINED_GENERATION")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Failing generation: deploy fails and the existing authority rolls back
      # to the snapshot generation. The consumed run is kept for retry.
      builder.succeed(
          "runuser -u operator -- sh -c " + shlex.quote(
              f"cd ${repo} && sed -e 's|@APP_DRV@|${broken.drv}|' -e 's|@APP_OUT@|${broken.out}|' ${flake} > flake.nix && "
              f"git add -A && {git} commit -qm broken"
          )
      )
      lines, error = fleet("deploy --strategy=agent --host app", expect="fail")
      assert check_handoff(lines, "app", retired=False) == "${broken.out}"
      assert "rolled back" in error, error[-3000:]
      assert app.succeed("readlink -f /run/current-system").strip() == "${next.out}"
      assert app.succeed("cat /etc/owned-deploy-marker").strip() == "next"
      builder.log("WORKFLOW_B_FAILED_DEPLOY_ROLLED_BACK")
      code, observed = owned(f"retire {lines[0]['run_id']}")
      assert code == 0, observed
      run_gone(lines[0]["run_id"])

      # Real worker OOM under the installed aggregate cap, not a synthetic
      # failure receipt. Control survives, settlement is observed and a following
      # admitted build still succeeds without raising any capacity limit.
      def memory_events():
          return dict((key, int(value)) for key, value in (line.split() for line in builder.succeed(f"cat {work_group}/memory.events").splitlines()))

      assert builder.succeed("cat /proc/sys/vm/panic_on_oom").strip() == "1"
      before_oom = memory_events()["oom_kill"]
      lines, error = fleet("build --strategy=agent --host pressure", expect="fail")
      assert [line["state"] for line in lines] == ["recorded"], lines
      assert memory_events()["oom_kill"] > before_oom
      builder.succeed("systemctl is-active abird-owned-build-supervisor.service abird-owned-build-control.socket")
      code, observed = owned(f"attach {lines[0]['run_id']} --wait-seconds 30")
      assert code == 0, observed
      code, observed = owned(f"retire {lines[0]['run_id']}")
      assert code == 0, observed
      run_gone(lines[0]["run_id"])
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)
      lines, _ = fleet("build --strategy=agent --host artifact")
      check_handoff(lines, "artifact")
      builder.log("WORKFLOW_RESOURCE_OOM_CONTROL_SURVIVED_NEXT_ADMISSION")

      # A separate caller has no builder checkout/account/store authority. Its
      # staged patch, ignored override and relative import must travel through
      # admitted capture, not be replaced with the builder's local repository.
      operator.succeed("runuser -u operator -- sh -c " + shlex.quote(
          "cd ${remoteRepo} && printf 'hosts/nixbot.override.nix\\nhosts/operator-selection.nix\\n' >> .git/info/exclude && "
          "printf 'import ./operator-selection.nix\\n' > hosts/nixbot.override.nix && "
          "printf '{ hosts.artifact.groups = [ \"remote-override\" ]; }\\n' > hosts/operator-selection.nix && "
          "sed -i s/owned-remote-artifact/owned-remote-staged/g flake.nix && git add flake.nix && "
          "sed -i s/owned-remote-staged/owned-remote-unstaged/g flake.nix"
      ))
      original_index = operator.succeed("sha256sum ${remoteRepo}/.git/index").split()[0]
      original_head = operator.succeed("runuser -u operator -- git -C ${remoteRepo} rev-parse HEAD").strip()
      lines, _ = fleet("build --strategy=agent --dirty-staged --group remote-override", caller=operator)
      path = check_handoff(lines, "artifact", caller=operator)
      assert operator.succeed(f"cat {path}").strip() == "built-owned-remote-staged"
      operator.succeed(f"runuser -u operator -- nix path-info --store daemon {path}")
      assert operator.succeed("sha256sum ${remoteRepo}/.git/index").split()[0] == original_index
      assert operator.succeed("runuser -u operator -- git -C ${remoteRepo} rev-parse HEAD").strip() == original_head
      builder.fail("test -e ${remoteHome}")
      builder.log("WORKFLOW_REMOTE_STAGED_OVERRIDE_SIGNED_COPYBACK")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Losing the remote caller must not create another capture/admission when
      # reconnecting to the already-running builder attempt.
      start("build --strategy=agent --dirty-staged --no-override --host slow", operator)
      builder.wait_until_succeeds("pgrep -f 'owned-slow-marke[r]'", timeout=600)
      recorded = json.loads(operator.succeed("cat /run/fleet.out").splitlines()[0])
      remote_run = recorded["run_id"]
      remote_attempts = recorded["attempts"]
      operator.succeed("systemctl kill --kill-whom=all --signal=KILL workflow-fleet.service")
      operator.wait_until_fails("systemctl is-active --quiet workflow-fleet.service")
      code, observed = owned(f"attach {remote_run} --wait-seconds 1", operator)
      assert code != 0, observed
      assert all(sum(j["acceptance"]["attempt_id"] == attempt for j in journal()["jobs"]) == 1 for attempt in remote_attempts)
      code, observed = owned(f"cancel {remote_run} --wait-seconds 90", operator)
      assert code == 0, observed
      code, observed = owned(f"retire {remote_run}", operator)
      assert code == 0, observed
      run_gone(remote_run, operator)
      operator.wait_until_succeeds("test -z \"$(systemctl list-units --state=active --no-legend 'abird-owned-capture@*.service')\"", timeout=60)
      builder.log("WORKFLOW_REMOTE_RECONNECTED_CANCELLED_CAPTURE_SETTLED")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # An external inventory has its own Git dependency root, including its
      # dirty tracked view. Its root must not inherit the target root's revision
      # or become an ordinary path snapshot. The target still uses staged bytes.
      operator.succeed("runuser -u operator -- sh -c " + shlex.quote(
          f"mkdir -p ${remoteHome}/inventory/hosts && cd ${remoteHome}/inventory && git init -q && "
          f"cp ${remoteInventory} hosts/nixbot.nix && chmod u+w hosts/nixbot.nix && "
          "sed -i '/dependency = /s/deploy = \"skip\"/deploy = \"strict\"/' hosts/nixbot.nix && "
          "printf '{ outputs = _: { nixbot.deployDependencies = {}; }; }\\n' > flake.nix && "
          "dd if=/dev/urandom of=.history-blob bs=1M count=42 status=none && "
          f"git add -A && {git} commit -qm external && git rm -q .history-blob && {git} commit -qm history-only && "
          "printf '{ outputs = { self }: { nixbot.deployDependencies.artifact = if (self.sourceInfo.dirtyRev or \"\") == \"%s-dirty\" then [ \"dependency\" ] else throw \"independent native Git identity lost\"; }; }\\n' \"$(git rev-parse HEAD)\" > flake.nix"
      ))
      lines, _ = fleet("build --strategy=agent --dirty-staged --no-override --host artifact --config ${remoteHome}/inventory/hosts/nixbot.nix", caller=operator)
      check_handoff(lines, "artifact", caller=operator)
      (external_outputs,) = lines[1]["outputs"].values()
      assert set(external_outputs) == {"artifact", "dependency"}, external_outputs
      assert operator.succeed(f"cat {external_outputs['dependency']['out']}").strip() == "built-owned-remote-dependency"
      assert int(operator.succeed("du -sb ${remoteHome}/inventory/.git").split()[0]) >= 42 * 1024 * 1024
      capture_events = dict(line.split() for line in operator.succeed("cat /sys/fs/cgroup/abird.slice/abird-build.slice/memory.events").splitlines())
      assert int(capture_events["oom_kill"]) == 0, capture_events
      builder.log("WORKFLOW_REMOTE_EXTERNAL_DIRTY_NATIVE_ROOT_REAL_42M_GIT")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Same shared Rust backend through the packaged Bash entry; development
      # builds use the current checkout even with --dirty-staged, preserving the
      # ordinary target projection and signed consumer handoff.
      bash_script = remote_script.replace("exec abird-host-manager fleet", "exec nixbot")
      operator.succeed("printf %s " + shlex.quote(bash_script) + " > /run/workflow-fleet.sh")
      lines, _ = fleet("dev-build --strategy=agent --dirty-staged --host artifact --no-override", caller=operator)
      development_path = check_handoff(lines, "artifact", caller=operator)
      assert operator.succeed("readlink -f ${remoteRepo}/result-dev/artifact").strip() == development_path
      operator.succeed("nix-store --gc")
      assert operator.succeed(f"cat {development_path}").strip() == "built-owned-remote-unstaged"
      operator.succeed("printf %s " + shlex.quote(remote_script) + " > /run/workflow-fleet.sh")
      builder.log("WORKFLOW_REMOTE_BASH_DEVBUILD_SHARED_BACKEND")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Actual caller callbacks through public remote Build, not direct policy
      # probes. The root collector only walks this recorded attempt; it archives
      # evidence outside the allocation before releasing each blocked callback.
      offline_tool = "${offlineFixture}/bin/owned-offline-fixture"
      offline_user = f"runuser -u operator -- env HOME=${remoteHome} {offline_tool}"
      operator.succeed(f"systemd-run --unit=owned-offline-listener --property=User=operator --collect --no-block {offline_tool} listen")
      operator.wait_until_succeeds("test -f ${remoteHome}/owned-offline-outside/ready.json", timeout=30)
      operator.succeed(f"{offline_user} preflight")
      operator.wait_until_succeeds("test -f ${remoteHome}/owned-offline-outside/armed.json", timeout=30)
      operator.succeed(f"{offline_user} configure")
      try:
          offline_arguments = "build --strategy=agent --dirty-staged --no-override --host artifact"
          start(offline_arguments, operator)
          operator.wait_until_succeeds("test -s /run/fleet.out || test -e /run/fleet.code", timeout=60)
          offline_recorded = json.loads(operator.succeed("head -n1 /run/fleet.out"))
          assert offline_recorded["state"] == "recorded", offline_recorded
          offline_run = offline_recorded["run_id"]
          (offline_attempt,) = offline_recorded["attempts"]
          # A callback waits for its collector, keeping this admitted input
          # listener open. Prove rejection AFTER authentication, not merely an
          # idle port or the ordinary sshd's input-account denial.
          builder.wait_until_succeeds("ss -ltn 'sport = :2022' | grep -q LISTEN", timeout=30)
          input_ssh = "ssh -F /dev/null -p 2022 -o HostKeyAlias=builder -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes"
          rejected, rejection = operator.execute(input_ssh + " -i /run/keys/owned-capture-relay owned-source-relay@builder 'touch /tmp/owned-relay-escaped' </dev/null 2>&1")
          assert rejected != 0 and "owned input relay rejected" in rejection, rejection
          builder.fail("test -e /tmp/owned-relay-escaped")
          rejected, rejection = operator.execute(input_ssh + " -i ${remoteHome}/.ssh/id_ed25519 owned-source-relay@builder true </dev/null 2>&1")
          assert rejected != 0 and "Permission denied" in rejection, rejection
          operator.succeed(f"{offline_tool} collect {shlex.quote(offline_attempt)}", timeout=630)
          lines, _ = finish(offline_arguments, caller=operator)
          assert lines[0]["run_id"] == offline_run and lines[0]["attempts"] == [offline_attempt]
          offline_path = check_handoff(lines, "artifact", caller=operator)
          assert operator.succeed(f"cat {offline_path}").strip() == "built-owned-remote-staged"
          operator.succeed(f"runuser -u operator -- nix path-info --store daemon {offline_path}")
      finally:
          # Restore before any subsequent ordinary Git setup can invoke a hook.
          operator.succeed(f"{offline_user} restore")
      operator.succeed(f"{offline_user} verify")
      operator.wait_until_succeeds("test -f ${remoteHome}/owned-offline-outside/final.json", timeout=30)
      operator.log(operator.succeed(f"{offline_tool} check"))
      builder.fail("test -e ${remoteHome}")
      builder.log("WORKFLOW_REMOTE_OFFLINE_FSMONITOR_REQUIRED_SMUDGE_SIGNED_HANDOFF")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Cold trust failure must not ACK/release. Reconcile the same immutable
      # acquisition once trust is restored; no duplicate builder execution.
      operator.succeed("nix-store --gc")
      operator.succeed("cp /etc/nix/nix.conf /run/original-nix.conf && sed '/trusted-public-keys/d' /run/original-nix.conf > /run/untrusted-nix.conf && cp --remove-destination /run/untrusted-nix.conf /etc/nix/nix.conf && systemctl restart nix-daemon")
      before_jobs = {j["acceptance"]["attempt_id"] for j in journal()["jobs"] if j["request"]["kind"] == "build"}
      lines, _ = fleet("build --strategy=agent --dirty-staged --host recover --no-override", expect="fail", caller=operator)
      assert [line["state"] for line in lines] == ["recorded"], lines
      failed_run = lines[0]["run_id"]
      operator.succeed("cp --remove-destination /run/original-nix.conf /etc/nix/nix.conf && systemctl restart nix-daemon")
      code, observed = owned(f"consume {failed_run}", caller=operator)
      assert code == 0, observed
      after_jobs = {j["acceptance"]["attempt_id"] for j in journal()["jobs"] if j["request"]["kind"] == "build"}
      assert after_jobs - before_jobs == set(lines[0]["attempts"]), after_jobs - before_jobs
      run_gone(failed_run, operator)
      builder.log("WORKFLOW_REMOTE_TRUST_FAILURE_SAME_ACQUISITION_RECOVERED")
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)

      # Explicit abandonment is not a fake ACK. Even without restoring trust,
      # cancellation + authenticated cleanup must release both run capacities.
      operator.succeed("cp --remove-destination /run/untrusted-nix.conf /etc/nix/nix.conf && systemctl restart nix-daemon")
      lines, _ = fleet("build --strategy=agent --dirty-staged --host discard --no-override", expect="fail", caller=operator)
      assert [line["state"] for line in lines] == ["recorded"], lines
      abandoned_run = lines[0]["run_id"]
      code, observed = owned(f"cancel {abandoned_run} --wait-seconds 90", operator)
      assert code == 0, observed
      code, observed = owned(f"retire {abandoned_run}", operator)
      assert code == 0, observed
      run_gone(abandoned_run, operator)
      abandoned_jobs = [j for j in journal()["jobs"] if j["acceptance"]["attempt_id"] in lines[0]["attempts"]]
      assert abandoned_jobs and all(j.get("consumer_abandonment") and not j.get("consumer_ack") for j in abandoned_jobs), abandoned_jobs
      builder.wait_until_succeeds(f"python3 -c {shlex.quote(builder_idle)}", timeout=120)
      operator.succeed("cp --remove-destination /run/original-nix.conf /etc/nix/nix.conf && systemctl restart nix-daemon")
      builder.log("WORKFLOW_REMOTE_FAILED_IMPORT_ABANDONED_BOTH_SIDES")

      # Remote retained deploy uses the ordinary target-local authority, never
      # builder-side activation or local re-evaluation/realization.
      lines, _ = fleet("deploy --strategy=agent --dirty-staged --no-override --host app --dry", caller=operator)
      assert check_handoff(lines, "app", caller=operator) == "${next.out}"
      lines, _ = fleet("deploy --strategy=agent --dirty-staged --no-override --host app", caller=operator)
      assert check_handoff(lines, "app", caller=operator) == "${next.out}"
      assert app.succeed("readlink -f /run/current-system").strip() == "${next.out}"
      builder.log("WORKFLOW_REMOTE_RETAINED_TARGET_DEPLOY")

      # Durable cancellation while the target is inside activation: builder
      # settlement must not complete cancel while its caller still owns forward
      # work. Once that in-flight action returns, rollback restores the previous
      # generation instead of dispatching health/later work.
      operator.succeed("runuser -u operator -- sh -c " + shlex.quote(
          "cd ${remoteRepo} && sed -i -e 's|${next.drv}|${blocked.drv}|' -e 's|${next.out}|${blocked.out}|' flake.nix && git add flake.nix"
      ))
      app.succeed("mkfifo -m 0600 /run/owned-activation-gate")
      arguments = "deploy --strategy=agent --dirty-staged --no-override --host app"
      start(arguments, operator)
      try:
          app.wait_until_succeeds("test -e /run/owned-activation-entered", timeout=600)
      except Exception:
          finish(arguments, caller=operator)
          raise
      recorded = json.loads(operator.succeed("cat /run/fleet.out").splitlines()[0])
      cancelled_run = recorded["run_id"]
      cancel = (
          "${pkgs.util-linux}/bin/runuser -u operator -- ${pkgs.coreutils}/bin/env -i HOME=${remoteHome} PATH=/run/current-system/sw/bin "
          f"abird-host-manager fleet owned cancel {cancelled_run} --wait-seconds 120 "
          "> /run/cancel.out 2>/run/cancel.err; echo $? > /run/cancel.code"
      )
      operator.succeed("systemd-run --unit=workflow-cancel --collect --no-block sh -c " + shlex.quote(cancel))
      operator.wait_until_succeeds(f"test -e ${remoteHome}/.local/state/abird/abird-host-manager/fleet-owned/{cancelled_run}/cancel.intent || test -e /run/cancel.code", timeout=30)
      if operator.execute("test -e /run/cancel.code")[0] == 0:
          operator.log(operator.succeed("tail -c 2048 /run/cancel.err"))
      operator.fail("test -e /run/cancel.code")
      code, observed = owned(f"status {cancelled_run}", operator)
      assert code == 0, observed
      observed = json.loads(observed)
      assert observed["settled"] and observed["settlement_scope"] == "builder" and observed["caller"] == "active", observed
      app.succeed("printf 'continue\\n' > /run/owned-activation-gate")
      lines, error = finish(arguments, expect="fail", caller=operator)
      assert [line["state"] for line in lines] == ["recorded", "consumed"], lines
      operator.wait_until_succeeds("test -e /run/cancel.code", timeout=120)
      assert operator.succeed("cat /run/cancel.code").strip() != "0"
      assert "target activation/rollback settlement remains unconfirmed" in operator.succeed("cat /run/cancel.err")
      # The independent observer verifies rollback; the cancel CLI does not
      # invent that proof from the departed caller's released flock.
      assert app.succeed("readlink -f /run/current-system").strip() == "${next.out}"
      code, observed = owned(f"retire {cancelled_run}", operator)
      assert code == 0, observed
      run_gone(cancelled_run, operator)
      builder.log("WORKFLOW_REMOTE_DURABLE_DEPLOY_CANCEL_ROLLED_BACK")

      # Managed CI must receive the explicit SHA/no-override source contract.
      builder.fail("runuser -u operator -- env -i HOME=${home} PATH=/run/current-system/sw/bin NIXBOT_EXECUTOR_KIND=managed sh -c " + shlex.quote("cd ${repo} && abird-host-manager fleet build --strategy=agent --host artifact"))
    '';
  }
