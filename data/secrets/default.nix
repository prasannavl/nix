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
    pvl-vlab = ./machine/pvl-vlab.key.pub;
    pvl-vk = ./machine/pvl-vk.key.pub;
    gap3-gondor = ./machine/gap3-gondor.key.pub;
  };
  machines = builtins.mapAttrs (_: keyPath: let
    recipient = builtins.replaceStrings ["\n"] [""] (builtins.readFile keyPath);
  in [recipient])
  machineKeyFiles;
  nixbotKeys = userdata.nixbot.sshKeys or [userdata.nixbot.sshKey];
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
    "data/secrets/machine/pvl-vlab.key.age".publicKeys = adminsWithNixbot;
    "data/secrets/machine/pvl-vk.key.age".publicKeys = adminsWithNixbot;
    "data/secrets/machine/gap3-gondor.key.age".publicKeys = adminsWithNixbot;

    # Cloudflare DNS
    "data/secrets/cloudflare/api-token.key.age".publicKeys = admins ++ pvl-x2;

    "data/secrets/cloudflare/r2-account-id.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-state-bucket.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-access-key-id.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/r2-secret-access-key.key.age".publicKeys = admins ++ pvl-x2;

    # GCP runtime auth
    "data/secrets/gcp/application-default-credentials.json.age".publicKeys = adminsWithNixbot;
    "data/secrets/gcp/state-bucket.key.age".publicKeys = adminsWithNixbot;
    "data/secrets/gcp/backend-impersonate-service-account.key.age".publicKeys = adminsWithNixbot;

    # Terraform Secrets
    "data/secrets/tf/cloudflare/globals.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare/account.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-dns/project-main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-dns/project-stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-dns/project-archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-dns/project-inactive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/access-account.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/tunnels-account.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/email-routing-main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/email-routing-archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/r2-main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-dnssec-main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-dnssec-stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-dnssec-archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-dnssec-inactive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-settings-main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-settings-archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-security-main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-security-stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-security-archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-platform/zone-security-inactive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-apps/project-main.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-apps/project-stage.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/cloudflare-apps/project-archive.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/gcp/globals.tfvars.age".publicKeys = adminsWithNixbot;
    "data/secrets/tf/gcp-bootstrap/globals.tfvars.age".publicKeys = adminsWithNixbot;

    # Cloudflare tunnels
    "data/secrets/cloudflare/tunnels/cert-p7log.com.pem.age".publicKeys = admins;
    "data/secrets/cloudflare/tunnels/cert-prasannavl.com.pem.age".publicKeys = admins;
    "data/secrets/cloudflare/tunnels/p7log-main.json.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/cloudflare/tunnels/prasannavl-main.json.age".publicKeys = admins ++ pvl-x2;

    # Tailscale
    "data/secrets/tailscale/pvl-vlab.key.age".publicKeys = admins ++ pvl-vlab;
    "data/secrets/tailscale/gap3-gondor.key.age".publicKeys = admins ++ gap3-gondor;

    # Services
    "data/secrets/services/beszel/key.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/beszel/token.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/app-secret.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/database-url.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/docmost/postgres-password.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/immich/db-password.key.age".publicKeys = admins ++ pvl-x2;
    "data/secrets/services/shadowsocks/password.key.age".publicKeys = admins ++ pvl-x2;
  }
