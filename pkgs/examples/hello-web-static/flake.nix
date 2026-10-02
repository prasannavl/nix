{
  description = "hello-web-static sample app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs:
    (import ../../../lib/flake/stack/package.nix).mkFlakeOutputs ./default.nix inputs;
}
