{
  description = "srv-ingest package";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }: let
    serviceModule = import ../../../lib/flake/service-module.nix;
  in
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      pkgHelper = import ../../../lib/flake/pkg-helper.nix;
      drv = pkgs.callPackage ./default.nix {};
    in
      pkgHelper.mkStdFlakeOutputs {
        pkgs = pkgs;
        build = drv;
        devShell = drv.devShell;
      })
    // {
      nixosModules = serviceModule.mkTcpServiceModules {
        self = self;
        name = "srv-ingest";
        bindEnvVar = "GAP3_API_INGEST_BIND_ADDR";
        listenAddressDescription = "IP address for the srv-ingest HTTP listener.";
        portDescription = "TCP port for the srv-ingest HTTP listener.";
        defaultPort = 3000;
      };
    };
}
