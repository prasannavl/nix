{
  hosts = {
    pvl-a1 = {
      target = "pvl-a1";
      ageIdentityKey = "data/secrets/machine/pvl-a1.key.age";
    };
    pvl-x2 = {
      target = "pvl-x2";
      ageIdentityKey = "data/secrets/machine/pvl-x2.key.age";
    };
    llmug-rivendell = {
      target = "llmug-rivendell";
      ageIdentityKey = "data/secrets/machine/llmug-rivendell.key.age";
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
