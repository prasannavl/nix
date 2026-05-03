{
  pkgs ? import <nixpkgs> {},
  s ? import ../../../lib/flake/stack.nix,
}: let
  pkg = s.pkg;
  srv = s.srv;
in
  pkg.mkRustDerivation {
    pkgs = pkgs;
    pname = "hello-rust-isolated";
    version = "0.1.0";
    src = ./.;
    meta = {
      description = "Isolated Rust hello world example";
      mainProgram = "hello-rust-isolated";
    };
    extraPassthru = {
      nixosModule = srv.mkModule {};
    };
  }
