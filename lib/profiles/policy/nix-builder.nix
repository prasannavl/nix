{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (config.services.nix-builder-gc-coordination.enable or false) {
    nix.settings = {
      max-jobs = lib.mkDefault 16;
      cores = lib.mkDefault 0;
      http-connections = lib.mkDefault 16;
    };
  };
}
