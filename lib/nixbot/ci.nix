{
  lib,
  pkgs,
  stacks,
  ...
}: let
  userdata = stacks.all.users.nixbot;
  forcedCommand = "${pkgs.nixbot}/bin/nixbot";
  forcedCommandKey = key: ''restrict,no-pty,no-agent-forwarding,no-port-forwarding,no-user-rc,no-X11-forwarding,command="${forcedCommand}" ${key}'';
  legacyKeyAgePath = ../../data/secrets/globals/nixbot/nixbot-legacy.key.age;
  hasLegacyKeyAge = builtins.pathExists legacyKeyAgePath;
in
  {
    users.users.nixbot.openssh.authorizedKeys.keys = map forcedCommandKey userdata.ciSshKeys;

    system.activationScripts.nixbotDeploy = ''
          install -d -m 0755 -o nixbot -g nixbot /var/lib/nixbot
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
  }
  // (let
    mkSecret = file: path: {
      file = file;
      path = path;
      owner = "nixbot";
      group = "nixbot";
      mode = "0400";
    };
  in {
    age.secrets.nixbot-ssh-key = mkSecret ../../data/secrets/globals/nixbot/nixbot.key.age "/var/lib/nixbot/.ssh/id_ed25519";

    age.secrets.nixbot-ssh-key-legacy = lib.mkIf hasLegacyKeyAge (
      mkSecret legacyKeyAgePath "/var/lib/nixbot/.ssh/id_ed25519_legacy"
    );
  })
