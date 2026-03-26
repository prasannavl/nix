{pkgs ? import <nixpkgs> {}}:
pkgs.rustPlatform.buildRustPackage {
  pname = "hello-rust";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  meta = {
    description = "Hello world Rust example";
    mainProgram = "hello-rust";
  };
}
