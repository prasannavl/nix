{pkgs}: let
  lib = pkgs.lib;
  evaluate = settings:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      pkgs = pkgs;
      modules = [
        ../default.nix
        {
          system.stateVersion = "26.05";
          users.users.tester = {
            isNormalUser = true;
            home = "/home/tester";
            packages = [pkgs.hello];
          };
          services.pi-web = {
            enable = true;
            user = "tester";
            package = pkgs.hello;
          };
        }
        settings
      ];
    }).config;
  defaults = evaluate {};
  disabled = evaluate {services.pi-web.mcp.enable = false;};
  off = evaluate {services.pi-web.enable = lib.mkForce false;};
  tailnet = evaluate {
    services.tailscale.enable = true;
    services.pi-web = {
      mcp.enable = false;
      tailnetAccess = true;
      allowedHosts = ["example.invalid"];
      environmentFile = "/run/credentials/pi-web";
    };
  };
  missingTailnet = evaluate {services.pi-web.tailnetAccess = true;};
  badBind = evaluate {
    services.tailscale.enable = true;
    services.pi-web = {
      tailnetAccess = true;
      bindAddress = "127.0.0.1";
    };
  };
  env = config: config.systemd.services.pi-web.serviceConfig.Environment;
  rejected = config: builtins.any (a: !a.assertion && lib.hasPrefix "services.pi-web." a.message) config.assertions;
in
  assert !(builtins.elem "PI_WEB_DISABLE_MCP=1" (env defaults));
  assert builtins.elem "PI_WEB_DISABLE_MCP=1" (env disabled);
  assert builtins.elem "PI_WEB_DISABLE_MCP=1" (env tailnet);
  assert builtins.elem "PI_WEB_ALLOWED_HOSTS=example.invalid" (env tailnet);
  assert tailnet.systemd.services.pi-web.serviceConfig.EnvironmentFile == "/run/credentials/pi-web";
  assert lib.hasInfix "--hostname 127.0.0.1" defaults.systemd.services.pi-web.serviceConfig.ExecStart;
  assert lib.hasInfix "--hostname 0.0.0.0" tailnet.systemd.services.pi-web.serviceConfig.ExecStart;
  assert lib.hasInfix ''iifname "tailscale0" tcp dport 30141 accept'' tailnet.networking.firewall.extraInputRules;
  assert !(off.systemd.services ? pi-web);
  assert rejected missingTailnet;
  assert rejected badBind;
  assert defaults.systemd.services.pi-web.path == defaults.users.users.tester.packages ++ [defaults.system.path];
  assert !defaults.systemd.services.pi-web.enableDefaultPath;
    pkgs.runCommand "pi-web-module-test" {} ''
      touch "$out"
    ''
