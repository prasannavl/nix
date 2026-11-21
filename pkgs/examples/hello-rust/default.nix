{
  pkgs,
  ab,
}:
ab.build.rust {
  pkgs = pkgs;
  pname = "hello-rust";
  version = "0.1.0";
  projectDir = "pkgs/examples/hello-rust";
  meta = {
    description = "Hello world Rust example";
    mainProgram = "hello-rust";
  };
  extraPassthru = {
    nixosModule = ab.nixos.service {};
  };
}
