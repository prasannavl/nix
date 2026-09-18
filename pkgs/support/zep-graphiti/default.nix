{
  lib,
  python3,
  stdenvNoCC,
}: let
  pname = "zep-graphiti";
  version = "0.1.0";
  graphitiRelease = builtins.fromJSON (builtins.readFile ./release.json);
  checkPython = python3.withPackages (ps: [ps.pydantic]);
  package = stdenvNoCC.mkDerivation {
    inherit pname version;
    src = ./app;

    dontConfigure = true;
    dontBuild = true;
    doCheck = true;

    checkPhase = ''
      runHook preCheck
      ${python3}/bin/python3 -m py_compile main.py
      ${checkPython}/bin/python3 -m unittest discover -s tests
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a ./. $out/
      cp ${./release.json} $out/release.json
      runHook postInstall
    '';

    passthru.graphitiRelease = graphitiRelease;

    meta = {
      description = "Graphiti FastAPI wrapper with Zep-compatible graph endpoints";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };
in
  package
