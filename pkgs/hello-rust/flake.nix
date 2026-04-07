{
  description = "hello-rust sample app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      build = pkgs.callPackage ./default.nix {};
    in {
      packages = {
        default = build;
        build = build;
        run = build;
      };
      apps = let
        run = {
          type = "app";
          program = pkgs.lib.getExe build;
          inherit (build) meta;
        };
      in {
        default = run;
        run = run;
      };
      checks = build.checks;
    })
    // {
      nixosModules = let
        helloRustModule = {
          config,
          lib,
          pkgs,
          ...
        }: let
          cfg = config.services.hello-rust;
        in {
          options.services.hello-rust = {
            enable = lib.mkEnableOption "hello-rust service";

            package = lib.mkOption {
              type = lib.types.package;
              inherit (self.packages.${pkgs.system}) default;
              defaultText = lib.literalExpression "self.packages.\${pkgs.system}.default";
              description = "The hello-rust package to run as a service.";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.hello-rust = {
              description = "hello-rust";
              wantedBy = ["multi-user.target"];
              after = ["network.target"];
              serviceConfig = {
                ExecStart = "${cfg.package}/bin/hello-rust";
                Restart = "on-failure";
              };
            };
          };
        };
      in {
        default = helloRustModule;
        hello-rust = helloRustModule;
      };
    };
}
