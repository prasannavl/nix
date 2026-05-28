{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack/package.nix,
}: let
  s = stack;
  pkg = s.pkg;
  srv = s.srv;
in
  pkg.mkRustDerivation {
    pkgs = pkgs;
    pname = "hello-rust";
    version = "0.1.0";
    projectDir = "pkgs/examples/hello-rust";
    meta = {
      description = "Hello world Rust example";
      mainProgram = "hello-rust";
    };
    extraPassthru = {
      nixosModule = srv.mkModule {};
    };
  }
