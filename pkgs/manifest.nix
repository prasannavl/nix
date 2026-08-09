{
  packages = {
    abird-host-agent = ./tools/abird-host-agent/default.nix;
    abird-host-manager = {
      path = ./tools/abird-host-manager/default.nix;
      rootApp = true;
    };
    nixbot = {
      path = ./tools/nixbot/default.nix;
      rootApp = true;
    };
    codex-wrapper = {
      path = ./tools/codex-wrapper/default.nix;
      apps.cr = [];
    };
    nats-wrecking-ball = ./tools/nats-wrecking-ball/default.nix;
    nats-http-bridge = ./support/nats-http-bridge/default.nix;
    nats-streams = ./support/nats-streams/default.nix;
    zep-graphiti = ./support/zep-graphiti/default.nix;
    zep-cloud-compat = ./support/zep-cloud-compat/default.nix;
    cloudflare-apps = {
      path = ./cloudflare-apps/default.nix;
      args = packages: {
        nixbot = packages.nixbot;
      };
      toolingPackages."cloudflare-apps/llmug-hello" = ["llmug-hello"];
      apps.cloudflare-apps-deploy = ["deploy"];
    };
    kanidm-server = ./ext/kanidm-server/default.nix;
    bulwarkmail = ./ext/bulwarkmail/default.nix;
    stalwart-server = ./ext/stalwart-server/default.nix;
    z-push = ./ext/z-push/default.nix;
    awl = ./ext/awl/default.nix;
    mirofish = ./ext/mirofish/default.nix;
    example-hello-go = {
      path = ./examples/hello-go/default.nix;
      rootApp = true;
    };
    example-hello-node = {
      path = ./examples/hello-node/default.nix;
      rootApp = true;
    };
    example-hello-python = {
      path = ./examples/hello-python/default.nix;
      rootApp = true;
    };
    example-hello-rust = {
      path = ./examples/hello-rust/default.nix;
      rootApp = true;
    };
    example-hello-rust-isolated = {
      path = ./examples/hello-rust-isolated/default.nix;
      rootApp = true;
    };
    example-hello-web-static = ./examples/hello-web-static/default.nix;
  };
}
