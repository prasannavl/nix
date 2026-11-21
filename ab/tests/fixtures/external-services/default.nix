{
  abCoreSource,
  abServicesSource,
  nixpkgsPath,
  system,
}: let
  pkgs = import nixpkgsPath {inherit system;};
  core = import abCoreSource;
  servicesComponent = import abServicesSource {inherit core;};
  ab = core.mk {
    inherit pkgs;
    extensions = [servicesComponent.extension];
  };

  machineIdSystem = import (nixpkgsPath + "/nixos/lib/eval-config.nix") {
    inherit pkgs system;
    modules = [
      ab.services.machineId.module
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/null";
          fsType = "ext4";
        };
        networking.hostName = "external-services-fixture";
        services."machine-id" = {
          enable = true;
          stateDir = "/var/sourcesernal-machine";
          opensshHostKeys.enable = false;
          runtimeHostname.enable = true;
        };
      }
    ];
  };

  nginxIngress = ab.services.nginx.model.normalize {
    http.proxies.api = {
      serverNames = ["api.example.test"];
      port = 18080;
      upstreams = ["127.0.0.1:18080"];
    };
  };

  nginxConfig = ab.services.nginx.renderer.http {
    ingress = nginxIngress;
  };
in {
  inherit ab core machineIdSystem nginxConfig nginxIngress pkgs servicesComponent;
}
