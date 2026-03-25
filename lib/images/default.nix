{
  inputs,
  commonModules,
  ...
}: let
  inherit (inputs) nixpkgs;
in {
  incus-base = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "nixos";
    };
    modules =
      commonModules
      ++ [
        ./incus-base.nix
      ];
  };
}
