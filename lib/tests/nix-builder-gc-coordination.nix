{pkgs}: let
  lib = pkgs.lib;
  lockPath = "/build/abird-nix-store-gc-test.lock";
  fakeAgent = pkgs.writeShellScriptBin "abird-host-agent" ''
    exit 0
  '';
  fakeGc = pkgs.writeShellScript "fake-nix-collect-garbage" ''
    printf '%s\n' "$@" >>/build/abird-nix-store-gc-test.args
  '';
  helpers = import ../services/nix-builder-gc-coordination/helpers.nix {
    inherit lib lockPath pkgs;
    nixCollectGarbageProgram = fakeGc;
  };
  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      ../services/abird-host-agent
      ../services/nix-builder-gc-coordination
      {
        networking.hostName = "builder-test";
        nix.gc = {
          automatic = true;
          options = "--delete-older-than 14d";
        };
        services = {
          abird-host-agent = {
            enable = true;
            package = fakeAgent;
          };
          nix-builder-gc-coordination.enable = true;
        };
      }
    ];
  };
  config = evalConfig.config;
  guardedGc = config.services.abird-host-agent.nixCollectGarbageProgram;
  configuredAgent = builtins.head (lib.splitString " " config.systemd.services.abird-host-agent-jobs.serviceConfig.ExecStart);
in
  assert config.nix.settings.min-free == 0;
  assert config.nix.settings.max-jobs == 1;
  assert !(lib.any (package: lib.hasInfix "abird-nix-build-lease" package.name) config.environment.systemPackages);
  assert !(builtins.any (lib.hasInfix "abird-nix-store-gc.lock") config.systemd.tmpfiles.rules);
  assert lib.hasInfix "flock --exclusive 9" config.systemd.services.nix-gc.script;
  assert lib.hasInfix "nix-collect-garbage --delete-older-than 14d" config.systemd.services.nix-gc.script;
    pkgs.runCommand "nix-builder-gc-coordination-test" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.util-linux];
    } ''
      grep -F -- ABIRD_HOST_AGENT_NIX_COLLECT_GARBAGE ${configuredAgent}
      grep -F -- ${lib.escapeShellArg guardedGc} ${configuredAgent}

      touch ${lockPath}
      flock --shared ${lockPath} sleep 30 &
      lease_pid=$!
      sleep 0.1
      if flock --nonblock --exclusive ${lockPath} true; then
        echo "exclusive GC lock passed an active build lease" >&2
        exit 1
      fi

      ${helpers.guardedGc}/bin/abird-nix-collect-garbage --delete-older-than 14d &
      gc_pid=$!
      sleep 0.1
      test ! -e /build/abird-nix-store-gc-test.args
      kill "$lease_pid"
      wait "$lease_pid" || :
      wait "$gc_pid"
      grep -Fx -- '--delete-older-than' /build/abird-nix-store-gc-test.args
      grep -Fx -- '14d' /build/abird-nix-store-gc-test.args

      touch "$out"
    ''
