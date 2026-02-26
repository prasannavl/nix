{
  pkgs,
  ...
}: let
  userdata = (import ../../users/userdata.nix).nixbot;
  bastionSshKeys = if userdata ? bastionSshKeys then userdata.bastionSshKeys else [userdata.bastionSshKey];
  forcedCommandKey = key: ''restrict,no-pty,no-agent-forwarding,no-port-forwarding,no-user-rc,no-X11-forwarding,command="/var/lib/nixbot/nixbot-deploy.sh" ${key}'';
in {
  users.users.nixbot.openssh.authorizedKeys.keys = map forcedCommandKey bastionSshKeys;

  system.activationScripts.nixbotSshGate = ''
    install -d -m 0755 -o nixbot -g nixbot /var/lib/nixbot
    install -m 0755 ${../../scripts/nixbot-deploy.sh} /var/lib/nixbot/nixbot-deploy.sh
    install -d -m 0700 -o nixbot -g nixbot /var/lib/nixbot/.ssh
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

  age.identityPaths = ["/var/lib/nixbot/.ssh/bootstrap_id_ed25519"];
}
