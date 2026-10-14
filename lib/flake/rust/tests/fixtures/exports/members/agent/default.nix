{
  pkgs,
  stack,
  pkgHelper,
}:
stack.pkg.mkRustDerivation {
  pkgs = pkgs;
  src = ../..;
  pname = "agent";
  projectDir = "members/agent";
  extraPassthru = {
    stackMarker = stack.org;
    bothHelperRoutes = pkgHelper.rustPlan {src = ../..;};
  };
}
