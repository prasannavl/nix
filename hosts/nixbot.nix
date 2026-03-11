{
  hosts = {
    pvl-a1 = {
      target = "pvl-a1";
      ageIdentityKey = "data/secrets/machine/pvl-a1.key.age";
      deps = [];
    };
    pvl-x2 = {
      target = "pvl-x2";
      ageIdentityKey = "data/secrets/machine/pvl-x2.key.age";
      deps = [];
    };
    llmug-rivendell = {
      target = "10.10.20.10";
      ageIdentityKey = "data/secrets/machine/llmug-rivendell.key.age";
      deps = [ "pvl-x2" ];
    };
  };

  defaults = {
    user = "nixbot";
    key = "data/secrets/nixbot/nixbot.key.age";
    bootstrapKey = "data/secrets/nixbot/nixbot.key.age";
    bootstrapUser = "pvl";
    knownHosts = null;
    ageIdentityKey = "";
  };
}
