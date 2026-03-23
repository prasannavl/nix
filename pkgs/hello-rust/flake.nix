{
  description = "hello-rust sample app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      build = pkgs.callPackage ./default.nix {};
      run = {
        type = "app";
        program = "${build}/bin/hello-rust";
      };
      check = args:
        build.overrideAttrs (old: {
          pname = "${old.pname}-${args.name}";
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ (args.nativeBuildInputs or []);
          buildPhase = args.buildPhase;
          installPhase = "touch $out";
          dontInstall = false;
        });
    in {
      packages = {
        default = build;
        inherit build;
        run = build;
      };
      apps = {
        default = run;
        inherit run;
      };
      checks = {
        inherit build;
        clippy = check {
          name = "clippy";
          nativeBuildInputs = [pkgs.clippy];
          buildPhase = "cargo clippy -- -D warnings";
        };
        fmt = check {
          name = "fmt";
          nativeBuildInputs = [pkgs.rustfmt];
          buildPhase = "cargo fmt --check";
        };
        test = check {
          name = "test";
          buildPhase = "cargo test";
        };
      };
    });
}
