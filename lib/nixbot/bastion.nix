{
  lib,
  pkgs,
  ...
}: let
  userdata = (import ../../users/userdata.nix).nixbot;
  bastionSshKeys = if userdata ? bastionSshKeys then userdata.bastionSshKeys else [userdata.bastionSshKey];
  forcedCommandKey = key: ''restrict,no-pty,no-agent-forwarding,no-port-forwarding,no-user-rc,no-X11-forwarding,command="/var/lib/nixbot/nixbot-deploy.sh" ${key}'';
  legacyKeyAgePath = ../../data/secrets/nixbot-legacy.key.age;
  hasLegacyKeyAge = builtins.pathExists legacyKeyAgePath;
in {
  users.users.nixbot.openssh.authorizedKeys.keys = map forcedCommandKey bastionSshKeys;

  system.activationScripts.nixbotDeploy = ''
    install -d -m 0755 -o nixbot -g nixbot /var/lib/nixbot
    install -m 0755 ${../../scripts/nixbot-deploy.sh} /var/lib/nixbot/nixbot-deploy.sh
    install -d -m 0700 -o nixbot -g nixbot /var/lib/nixbot/.ssh
    cat > /var/lib/nixbot/.ssh/config <<'EOF'
Host *
  IdentitiesOnly yes
  IdentityFile /var/lib/nixbot/.ssh/id_ed25519
  IdentityFile /var/lib/nixbot/.ssh/id_ed25519_legacy
EOF
    chown nixbot:nixbot /var/lib/nixbot/.ssh/config
    chmod 0600 /var/lib/nixbot/.ssh/config
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/nixbot/.ssh 0700 nixbot nixbot -"
  ];

  environment.systemPackages = with pkgs; [
    age
    jq
  ];

  age.secrets.nixbot-ssh-key = {
    file = ../../data/secrets/nixbot.key.age;
    path = "/var/lib/nixbot/.ssh/id_ed25519";
    owner = "nixbot";
    group = "nixbot";
    mode = "0400";
  };
  
  age.secrets.nixbot-ssh-key-legacy = lib.mkIf hasLegacyKeyAge {
    file = legacyKeyAgePath;
    path = "/var/lib/nixbot/.ssh/id_ed25519_legacy";
    owner = "nixbot";
    group = "nixbot";
    mode = "0400";
  };

  age.identityPaths =
    ["/var/lib/nixbot/.ssh/id_ed25519"]
    ++ lib.optional hasLegacyKeyAge "/var/lib/nixbot/.ssh/id_ed25519_legacy";
}
