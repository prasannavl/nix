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
    mkInstallerSet {
      installerName = targetName;
      targetConfigs = {
        ${targetName} = targetConfig;
      };
    };
  mkInstallerSet = {
    installerName,
    targetConfigs,
    installerProfile ? "minimal",
  }:
    mkNixosSystem {
      system = "x86_64-linux";
      hostName = "installer-${installerName}";
      stack = stacks.all;
      modules = [
        (import ./module.nix {
          installerName = installerName;
          installerProfile = installerProfile;
          targetConfigs = targetConfigs;
        })
      ];
    };
  mkInstallerProfiles = installerName: targetConfigs: {
    minimal = mkInstallerSet {
      installerName = installerName;
      installerProfile = "minimal";
      targetConfigs = targetConfigs;
    };
    gnome = mkInstallerSet {
      installerName = installerName;
      installerProfile = "gnome";
      targetConfigs = targetConfigs;
    };
  };
  mkDefaultInstallerSet = installerName: targetConfigs:
    (mkInstallerSet {
      installerName = installerName;
      targetConfigs = targetConfigs;
    })
    // {
      profiles = mkInstallerProfiles installerName targetConfigs;
    };
  legacyInstallerHostSets = builtins.mapAttrs mkDefaultInstallerSet installerHostSets;
  installerProfileHostSets = {
    minimal =
      builtins.mapAttrs
      (installerName: targetConfigs:
        mkInstallerSet {
          installerName = installerName;
          installerProfile = "minimal";
          targetConfigs = targetConfigs;
        })
      installerHostSets;
    gnome =
      builtins.mapAttrs
      (installerName: targetConfigs:
        mkInstallerSet {
          installerName = installerName;
          installerProfile = "gnome";
          targetConfigs = targetConfigs;
        })
      installerHostSets;
  };
  installerBundles =
    legacyInstallerHostSets
    // {
      profiles = installerProfileHostSets;
    };
in
  (builtins.mapAttrs mkInstaller installableHosts)
  // {
    bundle = installerBundles;
  }
