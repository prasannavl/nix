{lib, pkgs, ...}: let
  userdata = (import ../../users/userdata.nix).nixbot;
  sshGateScript = pkgs.replaceVars ./ssh-gate.sh {
    repoUrl = "ssh://git@github.com/prasannavl/nix.git";
  };
in {
  users.users.nixbot.openssh.authorizedKeys.keys = lib.mkAfter [
    ''restrict,no-pty,no-agent-forwarding,no-port-forwarding,no-user-rc,no-X11-forwarding,command="/var/lib/nixbot/ssh-gate.sh" ${userdata.bastionSshKey}''
  ];

  system.activationScripts.nixbotSshGate = ''
    install -d -m 0755 -o nixbot -g nixbot /var/lib/nixbot
    install -m 0755 -o root -g root ${sshGateScript} /var/lib/nixbot/ssh-gate.sh
    install -d -m 0700 -o nixbot -g nixbot /var/lib/nixbot/.ssh
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/nixbot/.ssh 0700 nixbot nixbot -"
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
