{pkgs ? import <nixpkgs> {}}:
pkgs.buildGoModule {
  pname = "hello-go";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  meta = {
    description = "Hello world Go example";
    mainProgram = "hello-go";
  };
}
