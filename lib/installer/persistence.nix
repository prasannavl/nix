{
  installerName,
  installerPersistence ? {},
  installerUsers ? {},
  repoSource,
  ...
}: {
  inputs,
  lib,
  pkgs,
  utils,
  ...
}: let
  allUserdata = import ../../users/userdata.nix;
  persistence =
    {
      enable = false;
      label = "NIXOS_PERSIST";
      mapperName = "nixos-persist";
      mountPoint = "/persist";
      passwordTimeoutSec = 45;
      paths = [
        "/etc/nixos"
        "/etc/NetworkManager/system-connections"
      ];
    }
    // installerPersistence;
  enabledInstallerUsers = lib.filterAttrs (_: userConfig: (userConfig.enable or false) || (userConfig.persistHome or false)) installerUsers;
  installerUserNames = builtins.attrNames enabledInstallerUsers;
  userProfilePath = userName: ../../users + "/${userName}/default.nix";
  userProfileExists = userName: builtins.pathExists (userProfilePath userName);
  userDataFor = userName:
    if builtins.hasAttr userName allUserdata
    then allUserdata.${userName}
    else throw "installer ${installerName}: installerUsers.${userName} is missing from users/userdata.nix";
  userGroupFor = userName: let
    userData = userDataFor userName;
  in
    userData.username or userName;
  userHomeFor = userName: let
    userConfig = enabledInstallerUsers.${userName};
  in
    userConfig.home or "/home/${userName}";
  userProfileFor = userName: enabledInstallerUsers.${userName}.profile or "core";
  userHasProfileImport = userName: userProfileFor userName != null && userProfileExists userName;
  profileUserNames = builtins.filter userHasProfileImport installerUserNames;
  fallbackUserNames = builtins.filter (userName: !(builtins.elem userName profileUserNames)) installerUserNames;
  persistedUserNames = builtins.filter (userName: persistence.enable && (enabledInstallerUsers.${userName}.persistHome or false)) installerUserNames;
  persistedHomeManagerUserNames = builtins.filter (userName: builtins.elem userName profileUserNames) persistedUserNames;
  persistedHomeManagerServices = map (userName: "home-manager-${utils.escapeSystemdPath userName}") persistedHomeManagerUserNames;
  persistedHomeManagerUnits = map (serviceName: "${serviceName}.service") persistedHomeManagerServices;
  persistedUserHomes = builtins.listToAttrs (map (userName: let
      userConfig = enabledInstallerUsers.${userName};
      home = userHomeFor userName;
    in {
      name = home;
      value = {
        path = home;
        relative = lib.removePrefix "/" home;
        init = "empty";
        source = "";
        owner = userName;
        group = userGroupFor userName;
        mode = userConfig.homeMode or "0700";
        writable = false;
      };
    })
    persistedUserNames);
  persistencePaths = lib.unique (persistence.paths ++ builtins.attrNames persistedUserHomes);
  userProfileImports =
    map
    (userName: let
      profileName = userProfileFor userName;
      profiles = import (userProfilePath userName);
    in
      if builtins.hasAttr profileName profiles
      then profiles.${profileName}
      else throw "installer ${installerName}: users/${userName} has no profile ${profileName}")
    profileUserNames;
  fallbackUserImports =
    map
    (userName: {
      config,
      lib,
      ...
    }: let
      userConfig = enabledInstallerUsers.${userName};
      userData = userDataFor userName;
      userGroup = userGroupFor userName;
      sshKeys = userData.sshKeys or (lib.optional (userData ? sshKey) userData.sshKey);
    in {
      users.groups.${userGroup} = {
        gid = userData.uid;
      };
      users.users.${userName} = {
        isNormalUser = true;
        description = userData.name or userName;
        uid = userData.uid;
        group = userGroup;
        hashedPassword = userData.hashedPassword or "!";
        home = userHomeFor userName;
        createHome = true;
        extraGroups =
          [
            "users"
            "wheel"
            "audio"
            "video"
          ]
          ++ lib.optional config.networking.networkmanager.enable "networkmanager"
          ++ (userConfig.extraGroups or []);
        openssh.authorizedKeys.keys = sshKeys;
      };
    })
    fallbackUserNames;
  installerUserOverrides = {
    users.users = builtins.listToAttrs (map (userName: let
        userConfig = enabledInstallerUsers.${userName};
      in {
        name = userName;
        value =
          {
            home = userHomeFor userName;
            createHome = lib.mkForce true;
          }
          // lib.optionalAttrs ((userConfig.extraGroups or []) != []) {
            extraGroups = userConfig.extraGroups;
          };
      })
      installerUserNames);
  };
  mkPersistencePathSpec = path:
    if path == "/etc/nixos"
    then {
      path = path;
      relative = "etc/nixos";
      init = "copy";
      source = toString repoSource;
      owner = "root";
      group = "root";
      mode = "0755";
      writable = true;
    }
    else if path == "/etc/NetworkManager/system-connections"
    then {
      path = path;
      relative = "etc/NetworkManager/system-connections";
      init = "empty";
      source = "";
      owner = "root";
      group = "root";
      mode = "0700";
      writable = false;
    }
    else if builtins.hasAttr path persistedUserHomes
    then persistedUserHomes.${path}
    else throw "installer ${installerName}: unsupported persistence path ${path}";
  persistencePathSpecs = pkgs.writeText "installer-persistence-paths.json" (builtins.toJSON (map mkPersistencePathSpec persistencePaths));
  persistenceTool = pkgs.writeShellApplication {
    name = "installer-persistence";
    excludeShellChecks = ["SC1091"];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.cryptsetup
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ];
    runtimeEnv = {
      INSTALLER_PERSISTENCE_LABEL = persistence.label;
      INSTALLER_PERSISTENCE_MAPPER_NAME = persistence.mapperName;
      INSTALLER_PERSISTENCE_MOUNT_POINT = persistence.mountPoint;
      INSTALLER_PERSISTENCE_PATH_SPECS = persistencePathSpecs;
      INSTALLER_PERSISTENCE_PASSWORD_TIMEOUT = toString persistence.passwordTimeoutSec;
    };
    text = ''
      source ${./persistence.sh}
      main "$@"
    '';
  };
in {
  imports =
    lib.optionals (userProfileImports != []) [
      inputs.home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = lib.mkDefault true;
        home-manager.useUserPackages = lib.mkDefault true;
      }
    ]
    ++ userProfileImports
    ++ fallbackUserImports
    ++ [
      installerUserOverrides
    ];

  systemd.services =
    {
      installer-persistence = lib.mkIf persistence.enable {
        description = "Unlock and mount optional encrypted installer persistence";
        wantedBy = ["multi-user.target"];
        wants = ["systemd-udev-settle.service"];
        after = [
          "local-fs.target"
          "systemd-udev-settle.service"
        ];
        before =
          [
            "NetworkManager.service"
            "display-manager.service"
            "systemd-user-sessions.service"
          ]
          ++ persistedHomeManagerUnits;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = persistence.passwordTimeoutSec + 15;
          ExecStart = "${persistenceTool}/bin/installer-persistence";
        };
      };
    }
    // lib.genAttrs persistedHomeManagerServices (_: {
      wants = ["installer-persistence.service"];
      after = ["installer-persistence.service"];
    });
}
