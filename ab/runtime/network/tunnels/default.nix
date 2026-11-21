{lib}: let
  cloudflare = import ./cloudflare.nix {inherit lib;};
  rathole = import ./rathole.nix {inherit lib;};
in {
  inherit cloudflare rathole;
  managed = import ./managed.nix {inherit cloudflare lib rathole;};
}
