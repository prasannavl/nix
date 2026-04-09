{pkgs}: {
  packageEntries = [
    {
      id = "nixbot";
      path = ./tools/nixbot/default.nix;
    }
    {
      id = "cloudflare-apps";
      rootApp = false;
      build = packages:
        pkgs.callPackage ./cloudflare-apps/default.nix {
          nixbot = packages.nixbot;
        };
      extraStdPackages = packages: {
        "cloudflare-apps/llmug-hello" = packages.cloudflare-apps.llmug-hello;
      };
      extraRootApps = packages: [
        {
          name = "cloudflare-apps-deploy";
          package = packages.cloudflare-apps.deploy;
        }
      ];
    }
    {
      id = "example-hello-go";
      path = ./examples/hello-go/default.nix;
    }
    {
      id = "example-hello-node";
      path = ./examples/hello-node/default.nix;
    }
    {
      id = "example-hello-python";
      path = ./examples/hello-python/default.nix;
    }
    {
      id = "example-hello-rust";
      path = ./examples/hello-rust/default.nix;
    }
    {
      id = "example-hello-web-static";
      path = ./examples/hello-web-static/default.nix;
      rootApp = false;
    }
  ];
}
