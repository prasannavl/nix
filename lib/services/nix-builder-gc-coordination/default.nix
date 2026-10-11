{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nix-builder-gc-coordination;
  # The Nix state directory is a stable inode on every usable builder. Locking
  # it avoids requiring a generation-provided helper or pre-created lock file.
  lockPath = "/nix/var/nix";
  flock = lib.getExe' pkgs.util-linux "flock";
  helpers = import ./helpers.nix {
    inherit lib lockPath pkgs;
  };
in {
  options.services.nix-builder-gc-coordination.enable =
    lib.mkEnableOption "coordination between Nix builder leases and garbage collection";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.abird-host-agent.enable;
        message = "services.nix-builder-gc-coordination requires services.abird-host-agent.enable.";
      }
    ];

    nix.settings = {
      # Shared failure domain: bound concurrency instead of Nix's unbounded
      # `auto`. 16 lanes keep a many-core builder busy during substitute and
      # fixed-output phases; connections stay under Nix's default 25.
      # `cores = 0` uses the effective CPU set.
      max-jobs = lib.mkDefault 16;
      http-connections = lib.mkDefault 16;
      # Nix daemon free-space GC cannot participate in this advisory lock. Keep
      # collection owned by the guarded scheduled and host-agent entrypoints.
      min-free = 0;
    };

    services.abird-host-agent.nixCollectGarbageProgram = lib.getExe helpers.guardedGc;

    systemd = {
      services.nix-gc.script = lib.mkBefore ''
        exec 9<${lib.escapeShellArg lockPath}
        ${flock} --exclusive 9
      '';
    };
  };
}
