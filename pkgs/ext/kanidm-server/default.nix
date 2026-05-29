{
  dockerTools,
  lib,
  stdenvNoCC,
}: let
  version = "1.10.1";
  imageBuild = "app-password-ui-${builtins.substring 0 12 (builtins.hashString "sha256" ''
    ${builtins.readFile ./app-passwords.js}
    ${builtins.readFile ./forms.js}
    config-v5
  '')}";

  imageName = "localhost/abird/kanidm-server";
  imageTag = "${version}-${imageBuild}";
  imageRef = "${imageName}:${imageTag}";

  upstreamImage = dockerTools.pullImage {
    imageName = "kanidm/server";
    imageDigest = "sha256:146df93ce06984f1061bd7d29e27dcb6a4fcc939fca34bee9f8fcd4c5f5bba25";
    finalImageName = "kanidm/server";
    finalImageTag = version;
    hash = "sha256-bk0Opkv8HC1Hp7wkxVuQtfNgjigjoPOELqfpoy2XcLw=";
  };

  uiLayer = stdenvNoCC.mkDerivation {
    pname = "kanidm-server-app-password-ui-layer";
    inherit version;
    src = ./.;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -D -m 0644 "$src/forms.js" "$out/hpkg/external/forms.js"
      install -D -m 0644 "$src/app-passwords.js" "$out/hpkg/app-passwords.js"
      runHook postInstall
    '';
  };

  image = dockerTools.buildImage {
    name = imageName;
    tag = imageTag;
    fromImage = upstreamImage;
    copyToRoot = uiLayer;

    config = {
      Cmd = [
        "/sbin/kanidmd"
        "server"
      ];
      ExposedPorts = {
        "3636/tcp" = {};
        "8443/tcp" = {};
      };
      Labels = {
        "com.kanidm.git-commit" = "e7cfe92ab54b9d7c2e363f04a69e3db1fc511fae";
        "com.kanidm.version" = version;
      };
      WorkingDir = "/data";
    };
  };
in
  image
  // {
    passthru = {
      inherit imageBuild imageName imageRef imageTag version;
      upstreamImageDigest = "sha256:146df93ce06984f1061bd7d29e27dcb6a4fcc939fca34bee9f8fcd4c5f5bba25";
    };

    meta = {
      description = "Kanidm server image with Abird app password UI";
      homepage = "https://github.com/kanidm/kanidm";
      license = lib.licenses.mpl20;
      platforms = lib.platforms.linux;
    };
  }
