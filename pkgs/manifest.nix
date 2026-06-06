{pkgs}: {
  packageEntries = [
    {
      id = "host-manager";
      path = ./tools/host-manager/default.nix;
    }
    {
      id = "nixbot";
      path = ./tools/nixbot/default.nix;
    }
    {
      id = "data-migrator";
      path = ./tools/data-migrator/default.nix;
    }
    {
      id = "nats-wrecking-ball";
      path = ./tools/nats-wrecking-ball/default.nix;
      rootApp = false;
    }
    {
      id = "nats-http-bridge";
      path = ./support/nats-http-bridge/default.nix;
      rootApp = false;
    }
    {
      id = "nats-streams";
      path = ./support/nats-streams/default.nix;
      rootApp = false;
    }
    {
      id = "zep-graphiti";
      path = ./support/zep-graphiti/default.nix;
      rootApp = false;
    }
    {
      id = "zep-cloud-compat";
      path = ./support/zep-cloud-compat/default.nix;
      rootApp = false;
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
      id = "kanidm-server";
      path = ./ext/kanidm-server/default.nix;
      rootApp = false;
    }
    {
      id = "bulwarkmail";
      path = ./ext/bulwarkmail/default.nix;
      rootApp = false;
    }
    {
      id = "stalwart-server";
      path = ./ext/stalwart-server/default.nix;
      rootApp = false;
    }
    {
      id = "z-push";
      path = ./ext/z-push/default.nix;
      rootApp = false;
    }
    {
      id = "awl";
      path = ./ext/awl/default.nix;
      rootApp = false;
    }
    {
      id = "mirofish";
      path = ./ext/mirofish/default.nix;
      rootApp = false;
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
      id = "example-hello-rust-isolated";
      path = ./examples/hello-rust-isolated/default.nix;
    }
    {
      id = "example-hello-web-static";
      path = ./examples/hello-web-static/default.nix;
      rootApp = false;
    }
  ];
}
