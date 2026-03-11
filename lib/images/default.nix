{
  inputs,
  commonModules,
  ...
}: let
  nixpkgs = inputs.nixpkgs;
in {
  incus-bootstrap = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostName = "incus-bootstrap";
    };
    modules = commonModules ++ [
      ./incus-bootstrap.nix
    ];
  };
}
