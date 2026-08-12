{
  pkgs,
  tailscale,
  ...
}: let
  version = "1.102.2";
in
  tailscale.overrideAttrs (finalAttrs: old: {
    version = version;

    src = pkgs.fetchFromGitHub {
      owner = "tailscale";
      repo = "tailscale";
      tag = "v${version}";
      hash = "sha256-vqNShvER4jT+8WJCcaSVboXPEP6S3QacmkC39tJkR4g=";
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
