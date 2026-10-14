{
  pkgs,
  pkgHelper,
  stack,
  agent ? pkgs.pkgs.callPackage ../agent {pkgHelper = pkgHelper;},
  # Test-only variants of the original constructor, not export/mirror knobs.
  omitSrc ? false,
  buildArgs ? {},
}:
pkgHelper.mkRustDerivation ({
    pkgs = pkgs;
    pname = "manager";
    projectDir = "members/manager";
    internalDeps =
      if agent == null
      then []
      else [agent];
    extraPassthru.stackMarker = stack.org;
  }
  // (
    if omitSrc
    then {}
    else {src = ../..;}
  )
  // buildArgs)
