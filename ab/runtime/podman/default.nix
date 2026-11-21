{pkgs}: {
  compose = import ./compose.nix {};
  facts = import ./facts.nix {lib = pkgs.lib;};
  firewallModule = ./firewall.nix;
  hostModule = ./host.nix;
  nixos = import ./nixos.nix;
  policy = import ./policy.nix {lib = pkgs.lib;};
  projection = import ./projection.nix {lib = pkgs.lib;};
  quadlet = import ./quadlet.nix {
    inherit pkgs;
    lib = pkgs.lib;
  };
  scripts = {
    composectl = ./composectl.sh;
    composeHelper = ./compose-helper.sh;
    globalHelper = ./helper.sh;
    imageHelper = ./image-helper.sh;
    quadletHelper = ./quadlet-helper.sh;
  };
}
