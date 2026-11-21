moduleArgs @ {
  lib,
  pkgs,
  ...
}: let
  ab = import ../ab;
  runtime = ab.runtime.mk {pkgs = pkgs;};
  nginx = import ../ab/services/nginx {inherit lib;};
  stackComponent = ab.stack;

  runtimePolicy = runtime.podman.policy;
  nginxPolicy = nginx.podman.policy;
  tunnelPolicy = stackComponent.tunnels.podman.policy {inherit lib;};

  module = runtime.podman.nixos {
    httpProbeForPort = runtimePolicy.httpProbeForPort;
    portExtraOptions =
      runtimePolicy.portOptions
      // nginxPolicy.portOptions
      // tunnelPolicy.portOptions;
    projectionModule = {
      imports = [
        runtime.podman.firewallModule
        ab.services.modules.abirdHostAgentPodmanAdapter
        (nginx.podman.projection {
          factProjection = runtime.podman.projection;
        })
        (stackComponent.tunnels.podman.projection {
          factProjection = runtime.podman.projection;
        })
      ];
    };
    stackExtraOptions = nginxPolicy.stackOptions;
  };
in
  module moduleArgs
