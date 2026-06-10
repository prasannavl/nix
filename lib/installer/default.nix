{
  mkNixosSystem,
  stacks,
  hosts,
  ...
}: let
  installableHosts = builtins.listToAttrs (
    builtins.map
    (name: {
      name = name;
      value = {
        hostName = name;
        config = hosts.${name};
      };
    })
    (
      builtins.filter
      (name: builtins.hasAttr "diskoScript" hosts.${name}.config.system.build)
      (builtins.attrNames hosts)
    )
  );
  installerHostSets = {
    all = installableHosts;
  };
  mkInstaller = targetName: targetConfig:
    mkInstallerSet targetName {
      ${targetName} = targetConfig;
    };
  mkInstallerSet = installerName: targetConfigs:
    mkNixosSystem {
      system = "x86_64-linux";
      hostName = "installer-${installerName}";
      stack = stacks.all;
      modules = [
        (import ./module.nix {
          installerName = installerName;
          targetConfigs = targetConfigs;
        })
      ];
    };
in
  (builtins.mapAttrs mkInstaller installableHosts)
  // {
    bundle = builtins.mapAttrs mkInstallerSet installerHostSets;
  }
