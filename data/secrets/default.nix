let
  userdata = import ../../users/userdata.nix;
    pvl = userdata.pvl.sshKey;
    nixbot = userdata.nixbot.sshKey;
in {
  "data/secrets/nixbot.key.age".publicKeys = [pvl nixbot];
  "data/secrets/nixbot-bastion-ssh.key.age".publicKeys = [pvl nixbot];
}
