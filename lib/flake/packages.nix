{
  pkgs,
  lint ? null,
}: let
  canonical = rec {
    hello-rust = pkgs.callPackage ../../pkgs/hello-rust/default.nix {};
    nixbot = pkgs.callPackage ../../pkgs/nixbot/default.nix {};
    cloudflare-apps = let
      llmugHello = pkgs.callPackage ../../pkgs/cloudflare-apps/llmug-hello/default.nix {};
    in
      pkgs.callPackage ../../pkgs/cloudflare-apps/default.nix {
        inherit nixbot llmugHello;
      };
  };
in
  canonical
  // (
    if lint == null
    then {}
    else lint.packages
  )
