{
  buildNpmPackage,
  dockerTools,
  fetchFromGitHub,
  lib,
  nodejs,
  perl,
  stdenvNoCC,
}: let
  source = (import ./sources.nix).mirofish;
  pname = "mirofish";
  inherit (source) version rev;
  shortRev = builtins.substring 0 12 rev;
  imageBuild = "src-${builtins.substring 0 12 (builtins.hashString "sha256" (builtins.readFile ./helper.sh))}";

  imageName = "localhost/abird/mirofish";
  imageTag = "${shortRev}-${imageBuild}";
  imageRef = "${imageName}:${imageTag}";

  src = fetchFromGitHub {
    inherit (source) owner repo;
    inherit rev;
    hash = source.srcHash;
  };

  upstreamRuntimeImage = dockerTools.pullImage {
    imageName = source.runtimeImage.name;
    imageDigest = source.runtimeImage.digest;
    finalImageName = source.runtimeImage.name;
    finalImageTag = source.runtimeImage.tag;
    sha256 = source.runtimeImage.hash;
  };

  patchedSource = stdenvNoCC.mkDerivation {
    pname = "mirofish-patched-source";
    inherit version src;
    nativeBuildInputs = [perl];
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -a ./. $out/
      chmod -R u+w $out

      source ${./helper.sh} "$out"

      runHook postInstall
    '';
  };

  rootNodeModules = buildNpmPackage {
    pname = "mirofish-root-node-modules";
    inherit version;
    src = patchedSource;
    npmDepsHash = source.rootNpmDepsHash;
    dontNpmBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a node_modules $out/node_modules
      runHook postInstall
    '';
  };

  frontendNodeModules = buildNpmPackage {
    pname = "mirofish-frontend-node-modules";
    inherit version;
    src = "${patchedSource}/frontend";
    npmDepsHash = source.frontendNpmDepsHash;
    dontNpmBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a node_modules $out/node_modules
      runHook postInstall
    '';
  };

  frontendDist = stdenvNoCC.mkDerivation {
    pname = "mirofish-frontend-dist";
    inherit version;
    src = patchedSource;
    nativeBuildInputs = [nodejs];
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      cp -a ${frontendNodeModules}/node_modules frontend/node_modules
      chmod -R u+w frontend/node_modules
      cd frontend
      VITE_API_BASE_URL=/ VITE_DEFAULT_LOCALE=en VITE_API_TIMEOUT_MS=900000 npm run build

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a dist/. $out/
      runHook postInstall
    '';
  };

  appLayer = stdenvNoCC.mkDerivation {
    pname = "mirofish-app-layer";
    inherit version;
    src = patchedSource;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/app
      cp -a ./. $out/app/
      chmod -R u+w $out/app
      rm -rf $out/app/node_modules $out/app/frontend/node_modules
      cp -a ${rootNodeModules}/node_modules $out/app/node_modules
      cp -a ${frontendNodeModules}/node_modules $out/app/frontend/node_modules
      rm -rf $out/app/frontend/dist
      mkdir -p $out/app/frontend/dist
      cp -a ${frontendDist}/. $out/app/frontend/dist/

      runHook postInstall
    '';
  };
  image = dockerTools.buildImage {
    name = imageName;
    tag = imageTag;
    fromImage = upstreamRuntimeImage;
    copyToRoot = appLayer;

    config = {
      WorkingDir = "/app";
      ExposedPorts = {
        "3000/tcp" = {};
        "5001/tcp" = {};
      };
      Cmd = [
        "sh"
        "-c"
        "./node_modules/.bin/concurrently --kill-others -n backend,frontend -c green,cyan \"cd backend && .venv/bin/python run.py\" \"cd frontend && npm run preview -- --host 0.0.0.0 --port 3000\""
      ];
    };
  };
in
  image
  // {
    passthru = {
      inherit
        imageName
        imageRef
        imageTag
        imageBuild
        rev
        shortRev
        src
        ;
      upstreamRuntimeDigest = source.runtimeImage.digest;
    };

    meta = {
      description = "MiroFish container image built from pinned upstream source";
      license = lib.licenses.agpl3Only;
      homepage = "https://github.com/666ghj/MiroFish";
      sourceProvenance = with lib.sourceTypes; [fromSource binaryBytecode];
      platforms = lib.platforms.linux;
    };
  }
