{
  pkgs,
  tailscale,
  ...
}: let
  source = (import ./sources.nix).tailscale;
in
  # tailscale 1.104+ needs Go >= 1.27.1; pinned nixpkgs Go is older.
  (tailscale.override {
    buildGoModule = pkgs.unstable.buildGo127Module;
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
