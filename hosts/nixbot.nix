{
  hosts = {
    pvl-a1 = {
      target = "pvl-a1";
      knownHosts = ''
        pvl-a1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDc4CcOlqS1B6mdvktzOdLjbfrCqi8xIFTW2QV+r69Jz
      '';
    };
    pvl-x2 = {
      target = "pvl-x2";
    };
    llmug-rivendell = {
      target = "llmug-rivendell";
    };
  };

  defaults = {
    user = "nixbot";
    key = "data/secrets/nixbot.key";
    knownHosts = null;
  };
}
