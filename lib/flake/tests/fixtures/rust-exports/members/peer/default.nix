{
  pkgs,
  stack,
}:
stack.pkg.mkRustDerivation {
  pkgs = pkgs;
  src = ../..;
  pname = "peer";
  projectDir = "members/peer";
}
