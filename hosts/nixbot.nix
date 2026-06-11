let
  secretPaths = rec {
    globals = "data/secrets/globals";
    machine = host: "${globals}/machine/${host}.key.age";
    nixbot = name: "${globals}/nixbot/${name}";
  };
  nixbotKey = secretPaths.nixbot "nixbot.key.age";
in {
  hosts = {
    pvl-a1 = {
      target = "pvl-a1";
      ageIdentityKey = secretPaths.machine "pvl-a1";
      deploy = "skip";
    };
    pvl-l5 = {
      target = "pvl-l5";
      ageIdentityKey = secretPaths.machine "pvl-l5";
      deploy = "optional";
    };
    pvl-x2 = {
      target = "pvl-x2";
      ageIdentityKey = secretPaths.machine "pvl-x2";
    };
    pvl-vlab = {
      target = "10.10.20.10";
      ageIdentityKey = secretPaths.machine "pvl-vlab";
      proxyJump = "pvl-x2";
      parent = "pvl-x2";
    };
    pvl-vlab-1 = {
      target = "10.10.20.30";
      ageIdentityKey = secretPaths.machine "pvl-vlab-1";
      proxyJump = "pvl-x2";
      parent = "pvl-x2";
    };
    pvl-vk = {
      target = "10.10.30.10";
      ageIdentityKey = secretPaths.machine "pvl-vk";
      proxyJump = "pvl-vlab";
      parent = "pvl-vlab";
    };
    pvl-vk-1 = {
      target = "10.10.50.31";
      ageIdentityKey = secretPaths.machine "pvl-vk-1";
      proxyJump = "pvl-x2";
      parent = "pvl-vlab-1";
    };
    gap3-gondor = {
      target = "10.10.20.11";
      ageIdentityKey = secretPaths.machine "gap3-gondor";
      proxyJump = "pvl-x2";
      parent = "pvl-x2";
      deploy = "skip";
    };
  };

  defaults = {
    user = "nixbot";
    key = nixbotKey;
    bootstrapKey = nixbotKey;
    bootstrapUser = "pvl";
    knownHosts = null;
    ageIdentityKey = "";
  };
}
