let
  userdata = import ../../users/userdata.nix;
  admins = [userdata.pvl.sshKey];
  adminsWithNixbot = admins ++ nixbotKeys;
  adminsWithCiHost =
    adminsWithNixbot
    ++ machines.pvl-x2;
  machineKeyFiles = {
    pvl-a1 = ./globals/machine/pvl-a1.key.pub;
    pvl-x2 = ./globals/machine/pvl-x2.key.pub;
    pvl-vlab = ./globals/machine/pvl-vlab.key.pub;
    pvl-vlab-1 = ./globals/machine/pvl-vlab-1.key.pub;
    pvl-vk = ./globals/machine/pvl-vk.key.pub;
    pvl-vk-1 = ./globals/machine/pvl-vk-1.key.pub;
    gap3-gondor = ./globals/machine/gap3-gondor.key.pub;
  };
  machines = builtins.mapAttrs (_: keyPath: let
    recipient = builtins.replaceStrings ["\n"] [""] (builtins.readFile keyPath);
  in [recipient])
  machineKeyFiles;
  nixbotKeys = userdata.nixbot.sshKeys or [userdata.nixbot.sshKey];
  globals = rec {
    base = "data/secrets/globals";
    file = name: "${base}/${name}";
    key = name: file "${name}.key.age";
    machineKey = host: key "machine/${host}";
    nixbotKey = name: key "nixbot/${name}";
    ciKey = name: key "ci/${name}";
    incusKey = name: key "incus/${name}";
    incusPfx = name: file "incus/${name}.pfx.age";
    cloudflareKey = name: key "cloudflare/${name}";
    gcpFile = name: file "gcp/${name}";
    tfFile = name: file "tf/${name}";
    tunnelFile = name: file "cloudflare/tunnels/${name}";
    tailscaleKey = host: key "tailscale/${host}";
  };
  stackArgs = {
    admins = admins;
    machines = machines;
  };
in
  with machines;
    {
      # Nixbot
      ${globals.nixbotKey "nixbot"}.publicKeys = adminsWithCiHost;
      ${globals.nixbotKey "nixbot-legacy"}.publicKeys = adminsWithCiHost;

      # CI host
      ${globals.ciKey "nixbot-ci-ssh"}.publicKeys = admins;

      # Machines
      ${globals.machineKey "pvl-a1"}.publicKeys = adminsWithNixbot;
      ${globals.machineKey "pvl-x2"}.publicKeys = adminsWithNixbot;
      ${globals.machineKey "pvl-vlab"}.publicKeys = adminsWithNixbot;
      ${globals.machineKey "pvl-vlab-1"}.publicKeys = adminsWithNixbot;
      ${globals.machineKey "pvl-vk"}.publicKeys = adminsWithNixbot;
      ${globals.machineKey "pvl-vk-1"}.publicKeys = adminsWithNixbot;
      ${globals.machineKey "gap3-gondor"}.publicKeys = adminsWithNixbot;

      # Incus client identities
      ${globals.incusKey "pvl"}.publicKeys = admins;
      ${globals.incusPfx "pvl"}.publicKeys = admins;
      ${globals.incusKey "abird"}.publicKeys = admins;
      ${globals.incusPfx "abird"}.publicKeys = admins;
      ${globals.incusKey "abird-stage"}.publicKeys = admins;
      ${globals.incusKey "abird-dev"}.publicKeys = admins;
      ${globals.incusPfx "abird-dev"}.publicKeys = admins;
      ${globals.incusKey "pvl-vlab-1"}.publicKeys = admins ++ pvl-vlab-1;

      # Cloudflare DNS
      ${globals.cloudflareKey "api-token"}.publicKeys = admins ++ pvl-x2;

      ${globals.cloudflareKey "r2-account-id"}.publicKeys = admins ++ pvl-x2;
      ${globals.cloudflareKey "r2-state-bucket"}.publicKeys = admins ++ pvl-x2;
      ${globals.cloudflareKey "r2-access-key-id"}.publicKeys = admins ++ pvl-x2;
      ${globals.cloudflareKey "r2-secret-access-key"}.publicKeys = admins ++ pvl-x2;

      # GCP runtime auth
      ${globals.gcpFile "application-default-credentials.json.age"}.publicKeys = adminsWithNixbot;
      ${globals.gcpFile "state-bucket.key.age"}.publicKeys = adminsWithNixbot;
      ${globals.gcpFile "backend-impersonate-service-account.key.age"}.publicKeys = adminsWithNixbot;

      # Terraform Secrets
      ${globals.tfFile "cloudflare/globals.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare/account.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-dns/project-main.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-dns/project-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-dns/project-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-dns/project-inactive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/access-account.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/tunnels-account.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/email-routing-main.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/email-routing-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/r2-main.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-dnssec-main.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-dnssec-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-dnssec-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-dnssec-inactive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-settings-main.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-settings-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-security-main.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-security-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-security-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-platform/zone-security-inactive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-apps/project-main.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-apps/project-stage.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "cloudflare-apps/project-archive.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "gcp/globals.tfvars.age"}.publicKeys = adminsWithNixbot;
      ${globals.tfFile "gcp-bootstrap/globals.tfvars.age"}.publicKeys = adminsWithNixbot;

      # Cloudflare tunnels
      ${globals.tunnelFile "p7log-main.json.age"}.publicKeys = admins ++ pvl-x2;
      ${globals.tunnelFile "prasannavl-main.json.age"}.publicKeys = admins ++ pvl-x2 ++ pvl-vlab;

      # Tailscale
      ${globals.tailscaleKey "pvl-vlab"}.publicKeys = admins ++ pvl-vlab;
      ${globals.tailscaleKey "gap3-gondor"}.publicKeys = admins ++ gap3-gondor;
    }
    // import ./pvl stackArgs
