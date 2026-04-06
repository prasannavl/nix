let
  mkCheck = build: args:
    build.overrideAttrs (old: {
      pname = "${old.pname}-${args.name}";
      nativeBuildInputs =
        (old.nativeBuildInputs or [])
        ++ (args.nativeBuildInputs or []);
      inherit (args) buildPhase;
      installPhase = "touch $out";
      dontInstall = false;
    });
in {
  mkCheck = mkCheck;

  mkChecks = build: checks:
    builtins.mapAttrs (name: args:
      if name == "build"
      then build
      else mkCheck build ({name = name;} // args))
    checks;
}
