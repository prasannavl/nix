{
  pkgs,
  tailscale,
  ...
}: let
  source = (import ./sources.nix).tailscale;
in
  tailscale.overrideAttrs (finalAttrs: old: {
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
