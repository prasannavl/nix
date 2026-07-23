{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optional optionals;
  types = lib.types;

  cfg = config.services.nixbot;

  mkBoolOption = default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };

  mkRestrictedKey = command: key: ''restrict,no-pty,no-agent-forwarding,no-port-forwarding,no-user-rc,no-X11-forwarding,command="${command}" ${key}'';

  repoSshKeyPaths = lib.concatStringsSep ":" cfg.sshClient.identityFiles;

  mkForcedCommand = name: repo:
    toString (pkgs.writeShellScript "nixbot-${name}-forced-command" ''
      export NIXBOT_REPO_URL=${lib.escapeShellArg repo.url}
      export NIXBOT_REPO_PATH=${lib.escapeShellArg repo.path}
      ${lib.optionalString (cfg.sshClient.identityFiles != []) ''
        export NIXBOT_REPO_SSH_KEY_PATHS=${lib.escapeShellArg repoSshKeyPaths}
      ''}
      exec ${cfg.package}/bin/nixbot "$@"
    '');

  repoType = types.submodule ({name, ...}: {
    options = {
      url = mkOption {
        type = types.str;
        example = "ssh://git@github.com/example/repo";
        description = "Git URL exported as NIXBOT_REPO_URL for this repo's forced-command wrapper.";
      };

      path = mkOption {
        type = types.str;
        default = "${cfg.stateDir}/${name}";
        defaultText = lib.literalExpression ''"${config.services.nixbot.stateDir}/<name>"'';
        description = "Persistent managed mirror path exported as NIXBOT_REPO_PATH.";
      };

      sshKeys = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Public SSH keys allowed to run this repo's restricted nixbot forced command.";
      };

      sshUser = mkOption {
        type = types.str;
        default = "nixbot-${name}";
        defaultText = lib.literalExpression ''"nixbot-<name>"'';
        description = "SSH user that receives this repo's forced-command keys.";
      };
    };
  });

  repoEntries =
    lib.mapAttrsToList (name: repo: let
      command = mkForcedCommand name repo;
    in {
      inherit name repo command;
      user = repo.sshUser;
      keys = map (mkRestrictedKey command) repo.sshKeys;
      keyClaims = map (key: "${repo.sshUser}\n${key}") repo.sshKeys;
    })
    cfg.repos;

  repoForcedKeysFor = user:
    lib.concatMap (entry: optionals (entry.user == user) entry.keys) repoEntries;

  repoUserNames = lib.unique (map (entry: entry.user) repoEntries);
  extraRepoUserNames = builtins.filter (user: user != cfg.user.name) repoUserNames;
  managedUsers =
    optional cfg.manage.user cfg.user.name
    ++ optionals cfg.forcedCommands.enable extraRepoUserNames;

  forcedKeyClaims = lib.concatMap (entry: entry.keyClaims) repoEntries;
  duplicateForcedKeys = forcedKeyClaims != lib.unique forcedKeyClaims;

  repoUsers = builtins.listToAttrs (map (user: {
      name = user;
      value = mkRepoUser user;
    })
    extraRepoUserNames);

  mkRepoUser = user: {
    isSystemUser = true;
    group = cfg.user.group;
    hashedPassword = "!";
    createHome = true;
    home = "/var/lib/${user}";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = repoForcedKeysFor user;
  };

  repoTmpfiles =
    lib.mapAttrsToList (
      _name: repo: "d ${repo.path} 0755 ${repo.sshUser} ${cfg.user.group} -"
    )
    cfg.repos;

  sshClientConfig = pkgs.writeText "nixbot-ssh-config" ''
    Host *
      IdentitiesOnly yes
    ${lib.concatMapStringsSep "\n" (path: "  IdentityFile ${path}") cfg.sshClient.identityFiles}
  '';

  primaryUserConfig = {
    users.groups.${cfg.user.group}.gid = cfg.user.uid;

    users.users.${cfg.user.name} = {
      uid = cfg.user.uid;
      group = cfg.user.group;
      isSystemUser = true;
      hashedPassword = "!";
      createHome = true;
      home = cfg.stateDir;
      shell = pkgs.bashInteractive;
      # Repo forced-command keys come first so a key accidentally listed in both
      # places remains restricted instead of gaining an unrestricted shell.
      openssh.authorizedKeys.keys =
        optionals cfg.forcedCommands.enable (repoForcedKeysFor cfg.user.name)
        ++ cfg.user.authorizedKeys;
    };
  };

  sudoConfig = {
    security.sudo.extraRules = [
      {
        users = managedUsers;
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };

  sshdPolicyConfig = {
    services.openssh.extraConfig = lib.mkAfter ''
      Match User ${lib.concatStringsSep "," managedUsers}
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        AuthenticationMethods publickey
    '';
  };

  ageIdentityConfig = {
    age.identityPaths = lib.mkAfter cfg.ageIdentity.paths;

    system.activationScripts.nixbotAgenixIdentityDir = ''
      install -d -m 0710 -o root -g ${cfg.user.group} ${cfg.stateDir}/.age
    '';

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir}/.age 0710 root ${cfg.user.group} -"
    ];
  };

  stateDirConfig = {
    system.activationScripts.nixbotHomeDir = ''
      install -d -m 0755 -o ${cfg.user.name} -g ${cfg.user.group} ${cfg.stateDir}
    '';

    systemd.tmpfiles.rules =
      [
        "d ${cfg.stateDir} 0755 ${cfg.user.name} ${cfg.user.group} -"
        "d ${cfg.stateDir}/activation-results 0700 root root 30d"
      ]
      ++ optionals cfg.forcedCommands.enable repoTmpfiles;
  };

  sshClientConfigFragment = {
    system.activationScripts.nixbotSshClientConfig = ''
      install -d -m 0750 -o ${cfg.user.name} -g ${cfg.user.group} "$(dirname ${lib.escapeShellArg cfg.sshClient.configPath})"
      install -m 0640 -o ${cfg.user.name} -g ${cfg.user.group} ${sshClientConfig} ${lib.escapeShellArg cfg.sshClient.configPath}
    '';

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir}/.ssh 0750 ${cfg.user.name} ${cfg.user.group} -"
    ];
  };

  cliExposureConfig = {
    environment.systemPackages = [
      cfg.package
    ];
  };
in {
  options.services.nixbot = {
    enable = mkEnableOption "nixbot system integration";

    package = mkOption {
      type = types.package;
      default = pkgs.nixbot;
      defaultText = lib.literalExpression "pkgs.nixbot";
      description = "nixbot package used by SSH forced-command wrappers and optional CLI exposure.";
    };

    cli =
      mkBoolOption false "Install nixbot into environment.systemPackages for interactive/admin use.";

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/nixbot";
      description = "Base runtime state directory for the primary nixbot account.";
    };

    user = {
      name = mkOption {
        type = types.str;
        default = "nixbot";
        description = "Primary nixbot user name.";
      };

      group = mkOption {
        type = types.str;
        default = "nixbot";
        description = "Primary nixbot group name.";
      };

      uid = mkOption {
        type = types.int;
        default = 10000;
        description = "UID for the primary nixbot user and group.";
      };

      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Unrestricted SSH public keys for the primary nixbot user.";
      };
    };

    manage = {
      user = mkBoolOption true "Create the primary nixbot user and group.";
      sudo = mkBoolOption true "Grant managed nixbot users passwordless sudo.";
      sshdPolicy = mkBoolOption true "Add OpenSSH Match rules that require public-key auth for managed nixbot users.";
      trustedUser = mkBoolOption true "Add managed nixbot users to nix.settings.trusted-users.";
      ageIdentity = mkBoolOption true "Add nixbot age identity paths and create the age identity directory.";
      stateDirs = mkBoolOption true "Create nixbot state directories through activation and tmpfiles.";
    };

    forcedCommands.enable =
      mkBoolOption true "Generate restricted SSH forced-command authorized_keys entries from services.nixbot.repos.";

    sshClient = {
      enable = mkBoolOption false "Create the nixbot SSH client config used for outbound Git and deploy SSH.";

      configPath = mkOption {
        type = types.str;
        default = "${cfg.stateDir}/.ssh/config";
        defaultText = lib.literalExpression ''"${config.services.nixbot.stateDir}/.ssh/config"'';
        description = "Path to the generated SSH client config.";
      };

      identityFiles = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "IdentityFile entries written to the generated SSH client config.";
      };
    };

    ageIdentity = {
      paths = mkOption {
        type = types.listOf types.str;
        default = [
          "${cfg.stateDir}/.age/identity"
        ];
        defaultText = lib.literalExpression ''[ "${config.services.nixbot.stateDir}/.age/identity" ]'';
        description = "Age identity paths registered for nixbot-owned activation and deploy flows.";
      };
    };

    repos = mkOption {
      type = types.attrsOf repoType;
      default = {};
      description = ''
        Repository-specific nixbot SSH ingress definitions. Each repo produces a
        restricted forced-command wrapper that exports NIXBOT_REPO_URL and
        NIXBOT_REPO_PATH before execing the generic nixbot package.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !duplicateForcedKeys;
          message = "services.nixbot.repos cannot assign the same SSH key to more than one repo for the same sshUser.";
        }
      ];
    }

    (mkIf cfg.manage.user primaryUserConfig)
    (mkIf (cfg.forcedCommands.enable && extraRepoUserNames != []) {users.users = repoUsers;})
    (mkIf (cfg.manage.sudo && managedUsers != []) sudoConfig)
    (mkIf (cfg.manage.sshdPolicy && managedUsers != []) sshdPolicyConfig)
    (mkIf (cfg.manage.trustedUser && managedUsers != []) {nix.settings.trusted-users = lib.mkAfter managedUsers;})
    (mkIf cfg.manage.ageIdentity ageIdentityConfig)
    (mkIf cfg.manage.stateDirs stateDirConfig)
    (mkIf cfg.sshClient.enable sshClientConfigFragment)
    (mkIf cfg.cli cliExposureConfig)
  ]);
}
