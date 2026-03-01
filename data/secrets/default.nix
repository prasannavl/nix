let
  userdata = import ../../users/userdata.nix;
  pvl = userdata.pvl.sshKey;
  nixbotKeys =
    if userdata.nixbot ? sshKeys
    then userdata.nixbot.sshKeys
    else [userdata.nixbot.sshKey];
  admins = [pvl];
  adminsWithNixbot = admins ++ nixbotKeys;
  adminsWithBastion =
    adminsWithNixbot
    ++ [
      machineRecipients.pvl-a1
      machineRecipients.pvl-x2
    ];
  machineRecipients = {
    pvl-a1 = builtins.replaceStrings ["\n"] [""] (builtins.readFile ./machine/pvl-a1.key.pub);
    pvl-x2 = builtins.replaceStrings ["\n"] [""] (builtins.readFile ./machine/pvl-x2.key.pub);
    llmug-rivendell = builtins.replaceStrings ["\n"] [""] (builtins.readFile ./machine/llmug-rivendell.key.pub);
  };
in {
  "data/secrets/nixbot/nixbot.key.age".publicKeys = adminsWithBastion;
  "data/secrets/nixbot/nixbot-legacy.key.age".publicKeys = adminsWithBastion;
  "data/secrets/bastion/nixbot-bastion-ssh.key.age".publicKeys = admins;
  "data/secrets/machine/pvl-a1.key.age".publicKeys = adminsWithNixbot;
  "data/secrets/machine/pvl-x2.key.age".publicKeys = adminsWithNixbot;
  "data/secrets/machine/llmug-rivendell.key.age".publicKeys = adminsWithNixbot;

  # Host machine recipients are intended for per-host runtime secret ACLs.
  # Example use:
  # "data/secrets/svc-foo.pvl-a1.age".publicKeys = [ machineRecipients.pvl-a1 ];
  # "data/secrets/svc-bar.pvl-x2.age".publicKeys = [ machineRecipients.pvl-x2 ];
}
