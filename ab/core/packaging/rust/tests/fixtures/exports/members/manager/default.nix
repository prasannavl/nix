{
  ab,
  pkgs,
  agent ? pkgs.pkgs.callPackage ../agent {inherit ab;},
  # Test-only variants of the original constructor, not export/mirror knobs.
  omitSrc ? false,
  viaWithDeps ? false,
  buildArgs ? {},
}: let
  build = agent:
    ab.build.rust ({
        pkgs = pkgs;
        pname = "manager";
        projectDir = "members/manager";
        internalDeps =
          if agent == null
          then []
          else [agent];
        extraPassthru.contextMarker = ab.testMarker or "ab-context";
      }
      // (
        if omitSrc
        then {}
        else {src = ../..;}
      )
      // buildArgs);
in
  if viaWithDeps
  then ab.package.withDeps {agent = agent;} ({agent}: build agent)
  else build agent
