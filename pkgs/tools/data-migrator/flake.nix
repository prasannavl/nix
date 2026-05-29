{
  description = "data-migrator";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs:
    (import ../../../lib/flake/stack/package.nix).mkFlakeOutputs ./default.nix (inputs
      // {
        systems = ["x86_64-linux"];
        stdFlakeOutputArgs = {build, ...}: {
          extraPackages = {
            data-migrator = build;
          };
        };
      });
}
