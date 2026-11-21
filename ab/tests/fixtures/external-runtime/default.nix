{
  abCoreSource,
  abRuntimeSource,
  nixpkgsPath,
  system,
}: let
  pkgs = import nixpkgsPath {inherit system;};
  core = import abCoreSource;
  runtimeComponent = import abRuntimeSource {inherit core;};
  ab = core.mk {
    inherit pkgs;
    extensions = [runtimeComponent.extension];
  };

  wireguardPeer = ab.runtime.network.wireguard.mkPeer {
    publicKey = "fixture-public-key";
    allowedIPs = ["10.88.0.2/32"];
    endpoint = "198.51.100.10:51820";
    persistentKeepalive = 25;
  };

  wireguardHelper = ab.runtime.network.wireguard.helperPackage;

  podmanSystem = import (nixpkgsPath + "/nixos/lib/eval-config.nix") {
    inherit pkgs system;
    modules = [
      (ab.runtime.podman.nixos {})
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/null";
          fsType = "ext4";
        };

        services.podman-compose.fixture = {
          backend = "compose";
          instances.web = {
            source.services.web = {
              image = "docker.io/library/busybox:latest";
              command = ["sleep" "infinity"];
            };
            exposedPorts.http = {
              port = 18080;
              protocols = ["tcp"];
            };
          };
        };
      }
    ];
  };

  podmanFact = podmanSystem.config._ab.runtime.podman.facts."fixture-web";
in {
  inherit ab core pkgs podmanFact runtimeComponent wireguardHelper wireguardPeer;
}
