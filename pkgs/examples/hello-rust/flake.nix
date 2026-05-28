{
  description = "hello-rust sample app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs:
    (import ../../../lib/flake/stack/package.nix).mkFlakeOutputs ./default.nix inputs;
}
