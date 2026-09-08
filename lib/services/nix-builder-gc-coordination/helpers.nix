{
  lib,
  pkgs,
  lockPath,
  nixCollectGarbageProgram ? "${pkgs.nix}/bin/nix-collect-garbage",
}: let
  flock = lib.getExe' pkgs.util-linux "flock";
  lock = lib.escapeShellArg lockPath;
in {
  guardedGc = pkgs.writeShellApplication {
    name = "abird-nix-collect-garbage";
    text = ''
      exec 9<${lock}
      ${flock} --exclusive 9
      exec ${lib.escapeShellArg nixCollectGarbageProgram} "$@"
    '';
  };
}
