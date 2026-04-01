{
  hosts = {
    pvl-a1 = {
      target = "pvl-a1";
      ageIdentityKey = "data/secrets/machine/pvl-a1.key.age";
      deploy = "optional";
    };
    pvl-x2 = {
      target = "pvl-x2";
      ageIdentityKey = "data/secrets/machine/pvl-x2.key.age";
    };
    pvl-vlab = {
      target = "10.10.20.10";
      ageIdentityKey = "data/secrets/machine/pvl-vlab.key.age";
      proxyJump = "pvl-x2";
      parent = "pvl-x2";
    };
    pvl-vk = {
      target = "10.10.30.10";
      ageIdentityKey = "data/secrets/machine/pvl-vk.key.age";
      proxyJump = "pvl-vlab";
      parent = "pvl-vlab";
    };
    gap3-gondor = {
      target = "10.10.20.11";
      ageIdentityKey = "data/secrets/machine/gap3-gondor.key.age";
      proxyJump = "pvl-x2";
      parent = "pvl-x2";
      # deploy = "skip";
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
