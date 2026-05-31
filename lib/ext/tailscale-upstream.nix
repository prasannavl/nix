{
  pkgs,
  tailscale,
  ...
}: let
  version = "1.98.3";
in
  tailscale.overrideAttrs (finalAttrs: old: {
    version = version;

    src = pkgs.fetchFromGitHub {
      owner = "tailscale";
      repo = "tailscale";
      tag = "v${version}";
      hash = "sha256-p+NEJVLLcwUNf3ZCXZEXAnTA5Pd6FlneMBZ0BcDYgXk=";
    };

    vendorHash = "sha256-mbxLXR2TBgiwyVGfLmMR5xWk+0f66mPDas95Wla70Lk=";

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
