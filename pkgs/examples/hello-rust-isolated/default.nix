{
  pkgs,
  ab,
}:
ab.build.rust {
  pkgs = pkgs;
  pname = "hello-rust-isolated";
  version = "0.1.0";
  src = ./.;
  meta = {
    description = "Isolated Rust hello world example";
    mainProgram = "hello-rust-isolated";
  };
  extraPassthru = {
    nixosModule = ab.nixos.service {};
  };
}
