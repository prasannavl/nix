{
  pkgs,
  settings ? {},
}:
import (pkgs.path + "/nixos/lib/eval-config.nix") {
  system = pkgs.stdenv.hostPlatform.system;
  pkgs = pkgs;
  modules = [
    ../../services/abird-host-agent
    ../../services/nix-builder-gc-coordination
    {
      networking.hostName = "builder-test";
      nix = {
        settings = settings;
        gc = {
          automatic = true;
          options = "--delete-older-than 14d";
        };
      };
      services = {
        abird-host-agent = {
          enable = true;
          package = pkgs.writeShellScriptBin "abird-host-agent" "exit 0";
        };
        nix-builder-gc-coordination.enable = true;
      };
    }
  ];
}
