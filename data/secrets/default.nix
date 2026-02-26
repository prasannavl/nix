let
  userdata = import ../../users/userdata.nix;
  pvl = userdata.pvl.sshKey;
  nixbotKeys = if userdata.nixbot ? sshKeys then userdata.nixbot.sshKeys else [userdata.nixbot.sshKey];
  recipients = [pvl] ++ nixbotKeys;
in {
  "data/secrets/nixbot.key.age".publicKeys = recipients;
  "data/secrets/nixbot-legacy.key.age".publicKeys = recipients;
  "data/secrets/nixbot-bastion-ssh.key.age".publicKeys = recipients;
}
