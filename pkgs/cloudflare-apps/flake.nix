{
  description = "cloudflare-apps aggregate build and deploy helpers";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = declaredInputs: let
    inputs = declaredInputs // {rustWorkspaceDeps = false;};
  in
    (import ../../nix/project.nix).mkFlakeOutputs ./. inputs;
}
