{
  pkgs,
  tailscale,
  ...
}: let
  version = "1.102.4";
in
  tailscale.overrideAttrs (finalAttrs: old: {
    version = version;

    src = pkgs.fetchFromGitHub {
      owner = "tailscale";
      repo = "tailscale";
      tag = "v${version}";
      hash = "sha256-PCCkzNvV9AK1AM5UhM97roSctctvFfwUw5QhKB64n00=";
    };

    vendorHash = "sha256-amKkUPszyhG4N5ZtrB01swBACYq76raSS+SQRneLmwc=";

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
