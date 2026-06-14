{
  lib,
  stack,
  stacks,
  ...
}: let
  userdata = stacks.all.users.nixbot;
  repoRoot = ./../..;
  secretsLib = import ../../lib/flake/secrets.nix;
  globals = secretsLib.mkGlobals {
    path = ../../data/secrets/globals;
  };
  nixbotStateDir = "/var/lib/nixbot";
  secretFile = secret: repoRoot + "/${globals.key secret}";
  mkDeployKey = {
    name,
    secret,
    path,
  }: {
    inherit name path;
    file = secretFile secret;
  };
  mkDeploySecret = key:
    stack.srv.mkSecret key.file {
      inherit (key) path;
      owner = "nixbot";
      group = "nixbot";
      mode = "0400";
    };
  nixbotDeploy = let
    deployKeySpecs =
      [
        {
          name = "nixbot-ssh-key";
          secret = "nixbot/nixbot";
          path = "${nixbotStateDir}/.ssh/id_ed25519";
        }
      ]
      ++ lib.optionals (builtins.pathExists (secretFile "nixbot/nixbot-legacy")) [
        {
          name = "nixbot-ssh-key-legacy";
          secret = "nixbot/nixbot-legacy";
          path = "${nixbotStateDir}/.ssh/id_ed25519_legacy";
        }
      ];
    deployKeys = map mkDeployKey deployKeySpecs;
  in {
    keyPaths = map (key: key.path) deployKeys;
    secrets =
      builtins.listToAttrs
      (map (key: {
          inherit (key) name;
          value = mkDeploySecret key;
        })
        deployKeys);
  };
in {
  services.nixbot = {
    enable = true;
    cli = true;

    sshClient = {
      enable = true;
      identityFiles = nixbotDeploy.keyPaths;
    };

    repos.nix = {
      url = "ssh://git@github.com/prasannavl/nix.git";
      path = "/var/lib/nixbot/nix";
      sshUser = "nixbot";
      sshKeys = userdata.ciSshKeys;
    };
  };

  age.secrets = nixbotDeploy.secrets;
}
