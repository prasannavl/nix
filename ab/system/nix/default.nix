{cachePolicy ? {}}: {lib, ...}: {
  nix.settings = {
    # A failed optional repository cache must not prevent other substitutes/builds.
    fallback = lib.mkIf ((cachePolicy.caches or {}) != {}) (lib.mkDefault true);
    experimental-features = ["nix-command" "flakes"];
    substituters = ["https://cache.nixos.org"];
    extra-substituters = lib.unique (cachePolicy.substituters or []);
    extra-trusted-public-keys = lib.unique (cachePolicy.trustedPublicKeys or []);
  };
}
