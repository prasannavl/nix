{core}:
assert core.name == "ab-core"; let
  ai = import ./ai;
  modules = {
    abirdHostAgent = ./abird-host-agent;
    abirdHostAgentNixosAdapter = import ./abird-host-agent/ab-nixos-adapter.nix {
      registryModule = core.registryModule;
    };
    abirdHostAgentPodmanAdapter = ./abird-host-agent/podman.nix;
    abirdHostManager = ./abird-host-manager;
    ai = ./ai/module.nix;
  };

  mk = {pkgs}:
    assert builtins.isAttrs pkgs; {
      abirdHostAgent = {
        module = modules.abirdHostAgent;
        nixosAdapter = modules.abirdHostAgentNixosAdapter;
        podmanAdapter = ./abird-host-agent/podman.nix;
      };
      abirdHostManager.module = modules.abirdHostManager;
      activesync = import ./activesync;
      inherit ai;
      fail2banHelper = {
        module = ./fail2ban-helper/default.nix;
      };
      excalidash = import ./excalidash {inherit pkgs;};
      forgejo = import ./forgejo {inherit pkgs;};
      hostNetworkQos = {
        module = ./host-network-qos/default.nix;
      };
      kache.module = ./kache;
      kanidm = import ./kanidm {
        lib = pkgs.lib;
        inherit pkgs;
      };
      llamaRouter = import ./llama-router {
        lib = pkgs.lib;
        inherit pkgs;
      };
      machineId = {
        module = ./machine-id/default.nix;
      };
      mailDirectory = import ./mail-directory {lib = pkgs.lib;};
      modelReconciler = import ./model-reconciler {
        lib = pkgs.lib;
        inherit pkgs;
      };
      nginx =
        (import ./nginx {lib = pkgs.lib;})
        // {
          helper = import ./nginx/helper.nix {inherit pkgs;};
          module = ./nginx/module.nix;
        };
      observability.vectorAgent.module = ./observability/vector-agent.nix;
      ollama = import ./ollama {
        lib = pkgs.lib;
        inherit pkgs;
      };
      piWeb = import ./pi-web;
      postgresExtensions =
        (import ./postgres-extensions {inherit pkgs;})
        // {
          release = import ./postgres-extensions/release.nix {inherit pkgs;};
        };
      stalwart = import ./stalwart {inherit pkgs;};
      support.userService = import ./support/user-service.nix;
      tailscale = import ./tailscale {lib = pkgs.lib;};
      zerobyte = import ./zerobyte {inherit pkgs;};
    };

  extension = {pkgs, ...}: {
    services = mk {pkgs = pkgs;};
  };
in {
  name = "ab-services";
  dependencies = {
    required = ["core"];
    optional = [];
  };

  inherit ai extension mk modules;
}
