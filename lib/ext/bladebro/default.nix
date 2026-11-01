{
  autoPatchelfHook,
  fetchzip,
  lib,
  makeWrapper,
  nodejs,
  stdenv,
  stdenvNoCC,
}: let
  pname = "bladebro";
  source = (import ./sources.nix).${pname};
  platform = stdenvNoCC.hostPlatform.system;
  release = source.releases.${platform};
  packageRoot = "$out/share/pi/packages/${pname}";

  # Fetch the optional platform payload directly, without npm resolution.
  binarySrc = fetchzip {
    url = "https://registry.npmjs.org/${release.package}/-/${release.package}-${source.version}.tgz";
    hash = release.hash;
  };
in
  stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = fetchzip {
      url = "https://registry.npmjs.org/${pname}/-/${pname}-${source.version}.tgz";
      hash = source.srcHash;
    };

    dontBuild = true;

    nativeBuildInputs = [
      autoPatchelfHook
      makeWrapper
    ];

    # Prebuilt Rust binary links glibc; autoPatchelf repairs the interpreter.
    buildInputs = [stdenv.cc.cc.lib];

    installPhase = ''
      runHook preInstall

      mkdir -p ${packageRoot}/node_modules/${release.package}
      cp -R . ${packageRoot}/
      cp -R ${binarySrc}/. ${packageRoot}/node_modules/${release.package}/
      chmod +x ${packageRoot}/node_modules/${release.package}/${pname}

      # Pi resolves the payload via require.resolve, so node_modules stays here.
      makeWrapper ${lib.getExe nodejs} $out/bin/${pname} \
        --add-flags ${packageRoot}/bin.js

      runHook postInstall
    '';

    meta = {
      description = "Stealthy agentic browser driver and Pi extension";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.asl20;
      mainProgram = pname;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
  }
