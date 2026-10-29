let
  inherit (import ../validation) mk;
  inherit (mk "invalid Nix cache policy") require requireOnly uniqueStrings;
  nonempty = value: builtins.isString value && value != "";
  identity = context: value:
    assert require (builtins.isAttrs value) "${context} must be an attribute set";
    assert requireOnly ["host" "fabric"] value context;
    assert require (nonempty (value.host or null)) "${context} requires a host";
    assert require ((value.fabric or null) == null || nonempty value.fabric) "${context} fabric must be null or nonempty"; {
      host = value.host;
      fabric = value.fabric or null;
    };
  normalizeCache = name: cache:
    assert require (builtins.isAttrs cache) "cache ${name} must be an attribute set";
    assert requireOnly ["url" "owner" "priority" "consumers"] cache "cache ${name}";
    assert require (cache ? url && builtins.isString cache.url && builtins.match "https?://[^?#[:space:]@]+" cache.url != null) "cache ${name} requires an HTTP(S) URL without credentials, query or fragment";
    assert require (builtins.isInt (cache.priority or 30) && (cache.priority or 30) >= 0) "cache ${name} priority must be a nonnegative integer"; let
      owner = identity "cache ${name} owner" (cache.owner or null);
      consumers =
        if (cache.consumers or null) == null
        then null
        else
          assert require (builtins.isList cache.consumers) "cache ${name} consumers must be a list or null";
            builtins.foldl' (seen: raw: let
              consumer = identity "cache ${name} consumer" raw;
            in
              assert require (!builtins.elem consumer seen) "cache ${name} duplicates a consumer";
                seen ++ [consumer]) []
            cache.consumers;
    in
      builtins.deepSeq {inherit owner consumers;} {
        url = cache.url;
        inherit owner consumers;
        priority = cache.priority or 30;
      };
in rec {
  normalize = caches:
    assert require (builtins.isAttrs caches) "caches must be a named attribute set"; let
      result = builtins.mapAttrs normalizeCache caches;
      urls = map (cache: cache.url) (builtins.attrValues result);
    in
      assert require (builtins.length (uniqueStrings "cache URLs" urls) == builtins.length urls) "cache URLs must be unique"; result;

  # Eligibility and store ownership are independent of the serving gateway.
  forHost = {
    policy,
    host,
    fabric ? null,
  }: let
    caches = normalize (policy.caches or {});
    consumer = {inherit host fabric;};
    selected =
      builtins.filter
      (cache: cache.owner != consumer && (cache.consumers == null || builtins.elem consumer cache.consumers))
      (builtins.attrValues caches);
    ordered = builtins.sort (a: b: a.priority < b.priority) selected;
  in
    policy
    // {
      substituters =
        map (cache: "${cache.url}?priority=${toString cache.priority}") ordered
        ++ (policy.substituters or []);
    };
}
