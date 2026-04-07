{pkgs}: let
  canonical = rec {
    hello-go = pkgs.callPackage ../../pkgs/hello-go/default.nix {};
    hello-node = pkgs.callPackage ../../pkgs/hello-node/default.nix {};
    hello-python = pkgs.callPackage ../../pkgs/hello-python/default.nix {};
    hello-rust = pkgs.callPackage ../../pkgs/hello-rust/default.nix {};
    hello-web-static = pkgs.callPackage ../../pkgs/hello-web-static/default.nix {};
    nixbot = pkgs.callPackage ../../pkgs/nixbot/default.nix {};
    cloudflare-apps = let
      llmugHello = pkgs.callPackage ../../pkgs/cloudflare-apps/llmug-hello/default.nix {};
    in
      pkgs.callPackage ../../pkgs/cloudflare-apps/default.nix {
        inherit nixbot llmugHello;
      };
    stdPackages = {
      inherit
        edi-ast-parser-rs
        gap3-ai-web
        hello-go
        hello-node
        hello-python
        hello-rust
        hello-web-static
        nixbot
        cloudflare-apps
        ;
      "cloudflare-apps/llmug-hello" = cloudflare-apps.llmug-hello;
    };
  };
in
  canonical
