{
  pkgs,
  tailscale,
  source ? (import ./sources.nix).tailscale,
  ...
}:
(tailscale.override {
  # Upstream name; our builder remains version-neutral.
  buildGo127Module = pkgs.unstable.buildGoModule.override {
    go =
      pkgs.go-bin.versions.${source.goVersion}
      or (throw "tailscale ${source.version} needs Go ${source.goVersion}; update the go-overlay input");
  };
}).overrideAttrs (finalAttrs: old: {
  version = source.version;

  src = pkgs.fetchFromGitHub {
    owner = "tailscale";
    repo = "tailscale";
    tag = "${source.tagPrefix}${source.version}";
    hash = source.srcHash;
  };

  vendorHash = source.vendorHash;

  ldflags =
    builtins.map
    (flag:
      if pkgs.lib.hasPrefix "-X tailscale.com/version." flag
      then
        pkgs.lib.replaceStrings
        [old.version]
        [finalAttrs.version]
        flag
      else flag)
    old.ldflags;
})
