{
  repoRoot,
  specFile,
}: let
  flake = builtins.getFlake repoRoot;
  lib = flake.inputs.nixpkgs.lib;
  system = "x86_64-linux";
  spec = builtins.fromJSON (builtins.readFile specFile);
  installerProfile = spec.installerProfile or "minimal";
  hosts = flake.nixosConfigurations;
  installableHostNames = builtins.filter (name: builtins.hasAttr "diskoScript" hosts.${name}.config.system.build) (builtins.attrNames hosts);
  rawTargets =
    if (spec.targets or {}) == {}
    then
      builtins.listToAttrs (builtins.map (name: {
          name = name;
          value = {
            host = name;
          };
        })
        installableHostNames)
    else spec.targets;
  targetConfigs = builtins.listToAttrs (
    builtins.map
    (targetName: let
      target = rawTargets.${targetName};
      hostName = target.host or (throw "Installer target ${targetName} is missing required host");
      host = hosts.${hostName};
      diskOverride = target.disk or null;
      idOverride = target.ids or null;
      modules = lib.optional (diskOverride != null || idOverride != null) (import ./storage-override.nix {
        inherit lib;
        disk = diskOverride;
        bootPartUuid =
          if idOverride == null
          then null
          else idOverride.bootPartUuid;
        rootPartUuid =
          if idOverride == null
          then null
          else idOverride.rootPartUuid;
        luksUuid =
          if idOverride == null
          then null
          else idOverride.luksUuid;
      });
      value =
        if modules == []
        then host
        else host.extendModules {modules = modules;};
    in
      if !(builtins.hasAttr hostName hosts)
      then throw "Unknown host for installer target ${targetName}: ${hostName}"
      else if !(builtins.hasAttr "diskoScript" host.config.system.build)
      then throw "Host is not installable by disko for installer target ${targetName}: ${hostName}"
      else {
        name = targetName;
        value = {
          hostName = hostName;
          config = value;
        };
      })
    (builtins.attrNames rawTargets)
  );
  installerModule = import ./module.nix {
    installerName = spec.installerName;
    installerProfile = installerProfile;
    targetConfigs = targetConfigs;
  };
in
  (flake.inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit system;
      inputs = flake.inputs;
      hostName = "installer-${spec.installerName}";
    };
    modules = [
      installerModule
    ];
  })
  .config
  .system
  .build
  .isoImage
