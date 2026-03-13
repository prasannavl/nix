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
  machines = builtins.mapAttrs (_: keyPath: let
    recipient = builtins.replaceStrings ["\n"] [""] (builtins.readFile keyPath);
  in [recipient])
  machineKeyFiles;
  adminsWithBastion =
    adminsWithNixbot
    ++ machines.pvl-x2;
in
  with machines; {
    "data/secrets/nixbot/nixbot.key.age".publicKeys = adminsWithBastion;
    "data/secrets/nixbot/nixbot-legacy.key.age".publicKeys = adminsWithBastion;

    "data/secrets/bastion/nixbot-bastion-ssh.key.age".publicKeys = admins;
    "data/secrets/machine/pvl-a1.key.age".publicKeys = adminsWithNixbot;
    "data/secrets/machine/pvl-x2.key.age".publicKeys = adminsWithNixbot;
    "data/secrets/machine/llmug-rivendell.key.age".publicKeys = adminsWithNixbot;

    "data/secrets/cloudflare/api-token.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-account-id.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-state-bucket.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-access-key-id.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-secret-access-key.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/zones-sensitive.auto.tfvars.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/tunnels/pvl-x2-main.credentials.json.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/tunnels/llmug-rivendell-main.credentials.json.age".publicKeys = admins ++ llmug-rivendell;

    "data/secrets/tailscale/llmug-rivendell.key.age".publicKeys = admins ++ llmug-rivendell;

    "data/secrets/services/beszel/key.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/beszel/token.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/app-secret.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/database-url.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/postgres-password.key.age".publicKeys = admins ++ pvl-x2;

    "data/secrets/services/immich/db-password.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/shadowsocks/password.key.age".publicKeys = admins ++ pvl-x2;
  }
