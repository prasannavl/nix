let
  joinWords = parts:
    builtins.concatStringsSep " " (builtins.filter (part: part != "") parts);

  mkCheckFn = build: args:
    build.overrideAttrs (old: {
      pname = "${old.pname}-${args.name}";
      nativeBuildInputs =
        (old.nativeBuildInputs or [])
        ++ (args.nativeBuildInputs or []);
      inherit (args) buildPhase;
      installPhase = "touch $out";
      dontInstall = false;
    });
in rec {
  mkCheck = mkCheckFn;

  mkChecks = build: checks:
    builtins.mapAttrs (name: args:
      if name == "build"
      then build
      else mkCheckFn build ({name = name;} // args))
    checks;

  rustFmt = pkgs: {cargoArgs ? []}: {
    nativeBuildInputs = [pkgs.rustfmt];
    buildPhase = joinWords (["cargo" "fmt"] ++ cargoArgs ++ ["--check"]);
  };

  rustClippy = pkgs: {
    cargoArgs ? [],
    lintArgs ? ["--" "-D" "warnings"],
    nativeBuildInputs ? [],
  }: {
    nativeBuildInputs = [pkgs.clippy] ++ nativeBuildInputs;
    buildPhase = joinWords (["cargo" "clippy"] ++ cargoArgs ++ lintArgs);
  };

  rustTest = _pkgs: {
    cargoArgs ? [],
    nativeBuildInputs ? [],
  }: {
    inherit nativeBuildInputs;
    buildPhase = joinWords (["cargo" "test"] ++ cargoArgs);
  };

  mkRustChecks = {
    build,
    pkgs,
    clippyCargoArgs ? [],
    clippyLintArgs ? ["--" "-D" "warnings"],
    fmtCargoArgs ? [],
    testCargoArgs ? [],
    extraChecks ? {},
  }: (builtins.mapAttrs (name: args:
      if name == "build"
      then build
      else mkCheckFn build ({name = name;} // args))
    ({
        build = {};
        fmt = rustFmt pkgs {cargoArgs = fmtCargoArgs;};
        clippy = rustClippy pkgs {
          cargoArgs = clippyCargoArgs;
          lintArgs = clippyLintArgs;
        };
        test = rustTest pkgs {cargoArgs = testCargoArgs;};
      }
      // extraChecks));
}
