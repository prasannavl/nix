{
  pkgs,
  tailscale,
  ...
}: let
  version = "1.98.9";
in
  tailscale.overrideAttrs (finalAttrs: old: {
    version = version;

    src = pkgs.fetchFromGitHub {
      owner = "tailscale";
      repo = "tailscale";
      tag = "v${version}";
      hash = "sha256-K8eQU/f5s6azGoOwN/0efmkP184t25aHBm5uZZNjIFg=";
    };

    vendorHash = "sha256-Sd2iLJ7eDfDYdIRuW4xuiKgzhQWJWGAnz97FJWrVRlE=";

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
