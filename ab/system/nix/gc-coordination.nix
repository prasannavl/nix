{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nix-builder-gc-coordination;
  gc = import ./guarded-gc.nix {
    inherit lib pkgs;
  };
in {
  options.services.nix-builder-gc-coordination = {
    enable = lib.mkEnableOption "coordination between Nix builder leases and garbage collection";
    collectGarbageProgram = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.getExe gc.guardedGc;
      description = "Guarded nix-collect-garbage entrypoint using the shared Nix state lock.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      min-free = 0;
    };

    systemd.services.nix-gc.script = lib.mkBefore gc.lockScript;
  };
}
