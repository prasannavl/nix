{
  lib,
  python3,
  stdenvNoCC,
}: let
  pname = "zep-cloud-compat";
  version = "0.1.0";
  package = stdenvNoCC.mkDerivation {
    inherit pname version;
    src = ./.;

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a zep_cloud/. $out/
      runHook postInstall
    '';

    passthru.tests.sdk-compat = stdenvNoCC.mkDerivation {
      pname = "${pname}-sdk-compat-test";
      inherit version;
      src = ./.;
      nativeBuildInputs = [python3];

      dontConfigure = true;
      dontBuild = true;
      doCheck = true;

      checkPhase = ''
        runHook preCheck
        python zep_cloud/tests/test_mirofish_sdk_compat.py
        runHook postCheck
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        touch $out/passed
        runHook postInstall
      '';
    };

    meta = {
      description = "Local zep-cloud SDK compatibility shim backed by Graphiti";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };
in
  package
