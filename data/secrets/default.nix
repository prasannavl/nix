let
  secretsLib = import ../../lib/flake/secrets.nix;
  userdata = (import ../../lib/stacks).all.users;
  admins = userdata.pvl.sshKeys;
  adminsWithNixbot = admins ++ nixbotKeys;
  deployMachines = machines.pvl-x2;
  adminsWithCiHost =
    adminsWithNixbot
    ++ deployMachines;
  globals = secretsLib.mkGlobals {
    path = ./globals;
  };
  machineIdentities = globals.machineIdentities {
    machines = {
      pvl-a1 = {};
      pvl-x2 = {};
      pvl-l5 = {};
      pvl-vlab = {};
      pvl-vlab-1 = {};
      pvl-vk = {};
      pvl-vk-1 = {};
      gap3-gondor = {};
    };
    defaultAccess = adminsWithNixbot;
  };
  machines = machineIdentities.recipients;
  nixbotKeys = userdata.nixbot.sshKeys;
  stackArgs = {
    admins = admins;
    machines = machines;
  };
in
  (with machines; {
    # Nixbot
    ${globals.key "nixbot/nixbot"}.publicKeys = adminsWithCiHost;
    ${globals.key "nixbot/nixbot-legacy"}.publicKeys = adminsWithCiHost;

    # CI host ingress
    ${globals.key "ci/nixbot-ci-ssh"}.publicKeys = admins;

    # Incus client identities
    ${globals.key "incus/pvl"}.publicKeys = admins;
    ${globals.file "incus/pvl.pfx.age"}.publicKeys = admins;
    ${globals.key "incus/abird"}.publicKeys = admins;
    ${globals.file "incus/abird.pfx.age"}.publicKeys = admins;
    ${globals.key "incus/abird-stage"}.publicKeys = admins;
    ${globals.key "incus/abird-dev"}.publicKeys = admins;
    ${globals.file "incus/abird-dev.pfx.age"}.publicKeys = admins;
    ${globals.key "incus/pvl-vlab-1"}.publicKeys = admins ++ pvl-vlab-1;

    # Cloudflare DNS
    ${globals.key "cloudflare/api-token"}.publicKeys = admins ++ pvl-x2;

    ${globals.key "cloudflare/r2-account-id"}.publicKeys = admins ++ pvl-x2;
    ${globals.key "cloudflare/r2-state-bucket"}.publicKeys = admins ++ pvl-x2;
    ${globals.key "cloudflare/r2-access-key-id"}.publicKeys = admins ++ pvl-x2;
    ${globals.key "cloudflare/r2-secret-access-key"}.publicKeys = admins ++ pvl-x2;

    # GCP runtime auth
    ${globals.file "gcp/application-default-credentials.json.age"}.publicKeys = adminsWithNixbot;
    ${globals.key "gcp/state-bucket"}.publicKeys = adminsWithNixbot;
    ${globals.key "gcp/backend-impersonate-service-account"}.publicKeys = adminsWithNixbot;

    # Terraform Secrets
    ${globals.file "tf/cloudflare/globals.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare/account.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-dns/project-main.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-dns/project-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-dns/project-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-dns/project-inactive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/access-account.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/tunnels-account.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/email-routing-main.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/email-routing-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/r2-main.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-dnssec-main.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-dnssec-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-dnssec-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-dnssec-inactive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-settings-main.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-settings-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-security-main.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-security-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-security-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-platform/zone-security-inactive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-apps/project-main.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-apps/project-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/cloudflare-apps/project-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/gcp/globals.tfvars.age"}.publicKeys = adminsWithNixbot;
    ${globals.file "tf/gcp-bootstrap/globals.tfvars.age"}.publicKeys = adminsWithNixbot;

    # Cloudflare Tunnels
    ${globals.file "cloudflare/tunnels/p7log-main.json.age"}.publicKeys = admins ++ pvl-x2;
    ${globals.file "cloudflare/tunnels/prasannavl-main.json.age"}.publicKeys = admins ++ pvl-x2 ++ pvl-vlab;

    # Tailscale
    ${globals.key "tailscale/pvl-vlab"}.publicKeys = admins ++ pvl-vlab;
    ${globals.key "tailscale/gap3-gondor"}.publicKeys = admins ++ gap3-gondor;
  })
  // machineIdentities.secrets
  // import ./pvl stackArgs
