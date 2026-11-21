{
  ab,
  pkgs,
}:
ab.build.rust {
  pkgs = pkgs;
  src = ../..;
  pname = "peer";
  projectDir = "members/peer";
}
