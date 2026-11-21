{
  description = "hello-web-static sample app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = declaredInputs: let
    inputs = declaredInputs // {rustWorkspaceDeps = false;};
  in
    (import ../../../lib/project.nix).mkFlakeOutputs ./. inputs;
}
