{
  ab,
  pkgs,
}:
ab.build.rust {
  pkgs = pkgs;
  src = ../..;
  pname = "agent";
  projectDir = "members/agent";
  extraPassthru.contextMarker = ab.testMarker or "ab-context";
}
