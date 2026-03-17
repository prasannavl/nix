let
  userdata = import ../../users/userdata.nix;
  admins = [userdata.pvl.sshKey];
  adminsWithNixbot = admins ++ nixbotKeys;
  adminsWithBastion =
    adminsWithNixbot
    ++ machines.pvl-x2;
  machineKeyFiles = {
    pvl-a1 = ./machine/pvl-a1.key.pub;
    pvl-x2 = ./machine/pvl-x2.key.pub;
    llmug-rivendell = ./machine/llmug-rivendell.key.pub;
  };
  machines = builtins.mapAttrs (_: keyPath: let
    recipient = builtins.replaceStrings ["\n"] [""] (builtins.readFile keyPath);
  in [recipient])
  machineKeyFiles;
  nixbotKeys =
    if userdata.nixbot ? sshKeys
    then userdata.nixbot.sshKeys
    else [userdata.nixbot.sshKey];
in
  with machines; {
    # Nixbot
    "data/secrets/nixbot/nixbot.key.age".publicKeys = adminsWithBastion;
    "data/secrets/nixbot/nixbot-legacy.key.age".publicKeys = adminsWithBastion;

    # Bastion
    "data/secrets/bastion/nixbot-bastion-ssh.key.age".publicKeys = admins;

    # Machines
    "data/secrets/machine/pvl-a1.key.age".publicKeys = adminsWithNixbot;
    "data/secrets/machine/pvl-x2.key.age".publicKeys = adminsWithNixbot;
    "data/secrets/machine/llmug-rivendell.key.age".publicKeys = adminsWithNixbot;

    # Cloudflare DNS
    "data/secrets/cloudflare/api-token.key.age".publicKeys = admins ++ pvl-x2;

    "data/secrets/cloudflare/r2-account-id.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-state-bucket.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-access-key-id.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-secret-access-key.key.age".publicKeys = admins ++ pvl-x2;

    # Terraform Secrets
    "data/secrets/tf/cloudflare/secrets.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/account/account.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/access/account.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/dns/main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/dns/stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/dns/archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/dns/inactive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/email-routing/main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/email-routing/archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/r2/main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/workers/main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/workers/stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/workers/archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-dnssec/main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-dnssec/stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-dnssec/archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-dnssec/inactive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-settings/main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-settings/archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-security/main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-security/stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-security/archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/zone-security/inactive.tfvars.age".publicKeys = adminsWithNixbot;

    # Cloudflare tunnels
    "data/secrets/cloudflare/tunnels/pvl-x2-main.credentials.json.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/tunnels/llmug-rivendell-main.credentials.json.age".publicKeys = admins ++ llmug-rivendell;

    # Tailscale
    "data/secrets/tailscale/llmug-rivendell.key.age".publicKeys = admins ++ llmug-rivendell;

    # Services
    "data/secrets/services/beszel/key.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/beszel/token.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/app-secret.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/database-url.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/postgres-password.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/immich/db-password.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/shadowsocks/password.key.age".publicKeys = admins ++ pvl-x2;
  }
