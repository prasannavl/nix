{
  hosts = {
    pvl-a1 = {
      target = "pvl-a1";
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
    key = "data/secrets/nixbot.key.age";
    bootstrapKey = "data/secrets/nixbot.key.age";
    bootstrapUser = "pvl";
    knownHosts = null;
  };
}
