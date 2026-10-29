{pkgs}: let
  cachePolicy = import ../nix-cache-policy.nix;
  cache = url: host: fabric: priority: {
    inherit url priority;
    owner = {inherit host fabric;};
  };
  policy = {
    caches = {
      base = cache "http://base-gateway.test:5000" "parent" null 10;
      platform = cache "http://ci.test:5000" "ci" "platform" 20;
      # A third layer and a second hostname for the same store are ordinary data.
      nested = cache "http://nested-ci.test:5000" "ci" "nested" 5;
      nestedAlias = cache "http://nested-alias.test:5000" "ci" "nested" 6;
    };
    substituters = ["https://public.test"];
    trustedPublicKeys = ["test-1:key"];
  };
  forHost = host: fabric: (cachePolicy.forHost {inherit policy host fabric;}).substituters;
  rejected = caches: !(builtins.tryEval (builtins.deepSeq (cachePolicy.normalize caches) true)).success;
  valid = policy.caches.platform;
  ciIdentity = {
    host = "ci";
    fabric = "platform";
  };
  scoped = cacheSpec: host: fabric:
    (cachePolicy.forHost {
      policy.caches.base = cacheSpec;
      inherit host fabric;
    }).substituters;
  upstream = policy.caches.base // {consumers = [ciIdentity];};
  clientSettings = caches:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit pkgs;
      system = pkgs.stdenv.hostPlatform.system;
      specialArgs.repository.nix = {
        inherit caches;
        substituters = [];
        trustedPublicKeys = [];
      };
      modules = [../../nix.nix];
    }).config.nix.settings;
in
  assert scoped upstream "ci" "platform" == ["http://base-gateway.test:5000?priority=10"];
  assert scoped upstream "ci" "nested" == [];
  assert scoped upstream "worker" "platform" == [];
  assert scoped upstream "ci" null == [];
  assert scoped (upstream // {consumers = [];}) "ci" "platform" == [];
  assert scoped (upstream // {consumers = null;}) "worker" null != [];
  assert scoped (upstream // {consumers = [policy.caches.base.owner];}) "parent" null == [];
  assert rejected {a = upstream // {consumers = "ci";};};
  assert rejected {a = upstream // {consumers = [ciIdentity ciIdentity];};};
  assert rejected {
    a =
      upstream
      // {
        consumers = [
          {host = "ci";}
          {
            host = "ci";
            fabric = null;
          }
        ];
      };
  };
  assert rejected {a = upstream // {consumers = [{host = "";}];};};
  assert rejected {
    a =
      upstream
      // {
        consumers = [
          {
            host = "ci";
            typo = true;
          }
        ];
      };
  };
  assert rejected {
    a =
      upstream
      // {
        consumers = [
          {
            host = "ci";
            fabric = [];
          }
        ];
      };
  };
  assert (clientSettings policy.caches).fallback;
  assert !((clientSettings {}).fallback or false);
  assert forHost "worker" "nested"
  == [
    "http://nested-ci.test:5000?priority=5"
    "http://nested-alias.test:5000?priority=6"
    "http://base-gateway.test:5000?priority=10"
    "http://ci.test:5000?priority=20"
    "https://public.test"
  ];
  assert forHost "ci" "nested"
  == [
    "http://base-gateway.test:5000?priority=10"
    "http://ci.test:5000?priority=20"
    "https://public.test"
  ];
  assert !(builtins.elem "http://ci.test:5000?priority=20" (forHost "ci" "platform"));
  assert builtins.elem "http://ci.test:5000?priority=20" (forHost "ci" null);
  assert !(builtins.elem "http://base-gateway.test:5000?priority=10" (forHost "parent" null));
  assert (cachePolicy.forHost {
    inherit policy;
    host = "worker";
  }).trustedPublicKeys
  == policy.trustedPublicKeys;
  assert (cachePolicy.forHost {
    policy = {substituters = ["https://legacy.test"];};
    host = "legacy";
  }).substituters
  == ["https://legacy.test"];
  assert rejected {
    a = valid;
    b = valid;
  };
  assert rejected {a = valid // {priority = -1;};};
  assert rejected {a = valid // {priority = "fast";};};
  assert rejected {a = valid // {owner = {host = "";};};};
  assert rejected {
    a =
      valid
      // {
        owner = {
          host = "ci";
          fabric = "";
        };
      };
  };
  assert rejected {
    a =
      valid
      // {
        owner = {
          host = "ci";
          typo = true;
        };
      };
  };
  assert rejected {a = valid // {url = "http://user:password@cache.test";};};
  assert rejected {a = valid // {url = "http://cache.test?priority=0";};};
  assert rejected {a = valid // {url = "file:///nix/store";};};
  assert rejected {a = valid // {typo = true;};};
    pkgs.runCommand "lib-flake-nix-cache-policy-test" {} ''
      touch "$out"
    ''
