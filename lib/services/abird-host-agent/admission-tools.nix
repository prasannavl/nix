{
  pkgs,
  host,
  agent,
  stateDirectory,
  backupRoot,
  hasDeclaredState,
  systemStateDirectory ? "/var/lib/abird-host-agent",
  runtimeDirectory ? "/run/abird-host-agent",
  configurationDirectory ? "/etc/abird-host-agent",
}: let
  lib = pkgs.lib;
  paths = import ../../validation/paths.nix {inherit lib;};
in
  assert lib.assertMsg
  (lib.all paths.isCanonicalAbsolutePath [stateDirectory backupRoot systemStateDirectory runtimeDirectory configurationDirectory])
  "host-agent admission directories must be canonical absolute paths"; {
    generation = pkgs.writeShellApplication {
      name = "abird-host-agent-generation-preflight";
      runtimeInputs = [pkgs.coreutils pkgs.jq];
      text =
        builtins.replaceStrings
        ["@JQ@" "@SHA256SUM@" "@HOST_AGENT@" "@HOST@" "@STATE_DIRECTORIES@" "@DATA_DIRECTORIES@" "@CONFIGURATION_DIRECTORY@" "@HAS_DECLARED_STATE@"]
        [
          (lib.getExe pkgs.jq)
          (lib.getExe' pkgs.coreutils "sha256sum")
          "${agent}/bin/abird-host-agent"
          host
          (lib.escapeShellArgs (lib.unique [stateDirectory systemStateDirectory]))
          (lib.escapeShellArgs (lib.unique [backupRoot "${systemStateDirectory}/backups" runtimeDirectory]))
          (lib.escapeShellArg configurationDirectory)
          (lib.boolToString hasDeclaredState)
        ]
        (builtins.readFile ./generation-preflight.sh);
    };
    statefulServicePlacement = pkgs.writeShellApplication {
      name = "abird-host-agent-stateful-service-placement-preflight";
      runtimeInputs = [pkgs.coreutils pkgs.jq];
      text =
        builtins.replaceStrings
        ["@JQ@" "@HOST_AGENT@" "@HOST@"]
        [(lib.getExe pkgs.jq) "${agent}/bin/abird-host-agent" host]
        (builtins.readFile ./stateful-service-placement-preflight.sh);
    };
  }
