{
  lib,
  pkgs,
}: {
  mkStateBinding = {
    legacyStateFile ? null,
    stateDirectory,
    stateName,
  }: let
    stateParts = lib.splitString "/" stateDirectory;
    validStateDirectory =
      stateDirectory
      != ""
      && !lib.hasPrefix "/" stateDirectory
      && lib.all (part: part != "" && part != "." && part != "..") stateParts;
    validStateName =
      stateName
      != ""
      && builtins.baseNameOf stateName == stateName
      && stateName != "."
      && stateName != "..";
  in {
    assertions = [
      {
        assertion = validStateDirectory;
        message = "model reconciler stateDirectory must be a safe relative systemd state directory";
      }
      {
        assertion = validStateName;
        message = "model reconciler stateName must be a safe basename";
      }
    ];
    environment =
      {
        MODEL_RECONCILER_STATE_NAME = stateName;
      }
      // lib.optionalAttrs (legacyStateFile != null) {
        MODEL_RECONCILER_LEGACY_STATE_FILE = legacyStateFile;
      };
    serviceConfig = {
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0750";
    };
  };

  mkApplication = {
    helper,
    name,
    runtimeEnv ? {},
    runtimeInputs ? [],
  }:
    pkgs.writeShellApplication {
      inherit name runtimeEnv runtimeInputs;
      text = ''
        export MODEL_RECONCILER_OWNERSHIP_LIB=${./ownership.sh}
        exec ${lib.getExe pkgs.bash} ${helper} "$@"
      '';
    };
}
