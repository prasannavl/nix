{
  pkgs,
  tailscale,
  ...
}: let
  source = (import ./sources.nix).tailscale;
in
  # base package comes from unstable (buildGo127Module; tailscale 1.104+ needs
  # Go >= 1.27.1, the pinned nixpkgs Go is older), we only pin the source.
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
