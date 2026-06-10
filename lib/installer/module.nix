{
  installerName,
  targetConfigs,
  ...
}: {
  inputs,
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  repoRoot = ../..;
  targetNames = builtins.attrNames targetConfigs;
  targetSpecs =
    lib.mapAttrs
    (targetName: targetConfig: let
      systemConfig = targetConfig.config;
      luksExtraFormatArgs = systemConfig.config.disko.devices.disk.main.content.partitions.root.content.extraFormatArgs;
      luksUuid =
        if builtins.length luksExtraFormatArgs >= 2 && builtins.elemAt luksExtraFormatArgs 0 == "--uuid"
        then builtins.elemAt luksExtraFormatArgs 1
        else throw "installer target ${targetName}: expected root LUKS extraFormatArgs to start with --uuid";
    in {
      host = targetConfig.hostName;
      system = systemConfig.config.system.build.toplevel;
      diskoScript = systemConfig.config.system.build.diskoScript;
      disk = systemConfig.config.disko.devices.disk.main.device;
      bootPartUuid = systemConfig.config.disko.devices.disk.main.content.partitions.boot.uuid;
      rootPartUuid = systemConfig.config.disko.devices.disk.main.content.partitions.root.uuid;
      luksUuid = luksUuid;
    })
    targetConfigs;
  targetStoreContents =
    lib.concatMap
    (targetName: let
      spec = targetSpecs.${targetName};
    in [
      spec.diskoScript
      spec.system
    ])
    targetNames;
  flakeInputSources =
    builtins.filter
    (path: path != null)
    (lib.mapAttrsToList
      (_: input:
        if input ? outPath
        then input.outPath
        else null)
      inputs);
  metadata = pkgs.writeText "${installerName}-offline-install-metadata.json" (builtins.toJSON {
    version = 1;
    installerName = installerName;
    targets =
      lib.mapAttrs
      (_: spec: {
        host = spec.host;
        system = toString spec.system;
        diskoScript = toString spec.diskoScript;
        disk = spec.disk;
        bootPartUuid = spec.bootPartUuid;
        rootPartUuid = spec.rootPartUuid;
        luksUuid = spec.luksUuid;
      })
      targetSpecs;
  });
  repoSource = lib.cleanSourceWith {
    src = repoRoot;
    filter = path: type: let
      root = toString repoRoot;
      rel = lib.removePrefix "${root}/" (toString path);
      base = baseNameOf path;
      isSecretKey =
        lib.hasPrefix "data/secrets/" rel
        && lib.hasSuffix ".key" rel;
    in
      !(
        base
        == ".git"
        || base == ".direnv"
        || base == "result"
        || lib.hasPrefix "result-" base
        || rel == "tmp"
        || lib.hasPrefix "tmp/" rel
        || isSecretKey
      );
  };
  genericInstall = pkgs.writeShellApplication {
    name = "generic-install-help";
    excludeShellChecks = ["SC1091"];
    text = ''
      source ${./generic-install-help.sh}
      main "$@"
    '';
  };
  offlineInstall = pkgs.writeShellApplication {
    name = "offline-install";
    excludeShellChecks = ["SC1091"];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.nix
      pkgs.nixos-install-tools
      pkgs.util-linux
    ];
    runtimeEnv.NIXOS_OFFLINE_INSTALL_METADATA = metadata;
    text = ''
      source ${./offline-install.sh}
      main "$@"
    '';
  };
in {
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
  ];

  image.baseName = lib.mkForce "${installerName}-installer";

  isoImage = {
    squashfsCompression = "zstd -Xcompression-level 6";
    storeContents =
      [
        genericInstall
        offlineInstall
        repoSource
      ]
      ++ flakeInputSources
      ++ targetStoreContents;
  };

  networking.hostName = "installer-${installerName}";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment = {
    etc."nixos".source = repoSource;
    systemPackages = [
      genericInstall
      offlineInstall
      pkgs.git
      pkgs.nixos-install-tools
      pkgs.parted
      pkgs.ripgrep
    ];
  };

  users.users.nixos.initialHashedPassword = lib.mkForce "";
  services.openssh.enable = lib.mkDefault true;
}
