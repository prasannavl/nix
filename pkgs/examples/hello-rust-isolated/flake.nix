{
  description = "isolated hello-rust sample app";

  inputs = {
    crane.url = "github:ipetkov/crane/v0.24.0";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs:
    (import ../../../lib/flake/stack/package.nix).mkFlakeOutputs ./default.nix inputs;
}
