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
      # The cache builder is a shared failure domain. Admit one derivation at a
      # time while leaving `cores = 0` to give it the effective CPU set.
      max-jobs = lib.mkDefault 1;
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
