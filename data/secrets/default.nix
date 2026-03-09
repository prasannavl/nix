let
  userdata = import ../../users/userdata.nix;
  pvl = userdata.pvl.sshKey;
  nixbotKeys =
    if userdata.nixbot ? sshKeys
    then userdata.nixbot.sshKeys
    else [userdata.nixbot.sshKey];
  admins = [pvl];
  adminsWithNixbot = admins ++ nixbotKeys;
  machineKeyFiles = {
    pvl-a1 = ./machine/pvl-a1.key.pub;
    pvl-x2 = ./machine/pvl-x2.key.pub;
    llmug-rivendell = ./machine/llmug-rivendell.key.pub;
  };
  machines =
    builtins.mapAttrs (_: keyPath: let
      recipient = builtins.replaceStrings ["\n"] [""] (builtins.readFile keyPath);
    in {
      inherit recipient;
      withAdmins = admins ++ [recipient];
    })
    machineKeyFiles;
  adminsWithBastion =
    adminsWithNixbot
    ++ [
      machines.pvl-a1.recipient
      machines.pvl-x2.recipient
    ];
in {
  "data/secrets/nixbot/nixbot.key.age".publicKeys = adminsWithBastion;
  "data/secrets/nixbot/nixbot-legacy.key.age".publicKeys = adminsWithBastion;
  "data/secrets/bastion/nixbot-bastion-ssh.key.age".publicKeys = admins;
  "data/secrets/machine/pvl-a1.key.age".publicKeys = adminsWithNixbot;
  "data/secrets/machine/pvl-x2.key.age".publicKeys = adminsWithNixbot;
  "data/secrets/machine/llmug-rivendell.key.age".publicKeys = adminsWithNixbot;
  "data/services/beszel/key.age".publicKeys = machines.pvl-x2.withAdmins;
  "data/services/beszel/token.age".publicKeys = machines.pvl-x2.withAdmins;
  "data/services/docmost/app-secret.age".publicKeys = machines.pvl-x2.withAdmins;
  "data/services/docmost/database-url.age".publicKeys = machines.pvl-x2.withAdmins;
  "data/services/docmost/postgres-password.age".publicKeys = machines.pvl-x2.withAdmins;
  "data/services/immich/db-password.age".publicKeys = machines.pvl-x2.withAdmins;
  "data/services/shadowsocks/password.age".publicKeys = machines.pvl-x2.withAdmins;

  # Host machine recipients are intended for per-host runtime secret ACLs.
  # Example use:
  # "data/secrets/svc-foo.pvl-a1.age".publicKeys = machines.pvl-a1.withAdmins;
  # "data/secrets/svc-bar.pvl-x2.age".publicKeys = machines.pvl-x2.withAdmins;
}
