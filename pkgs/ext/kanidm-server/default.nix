{
  dockerTools,
  lib,
  stdenvNoCC,
  appLinksMetadata ? [],
}: let
  version = "1.10.3";
  uiAssets = {
    "external/forms.js" = ./forms.js;
    "app-passwords.js" = ./app-passwords.js;
    "app-links.js" = ./app-links.js;
    "override.css" = ./override.css;
    "style.js" = ./style.js;
  };
  appLinksData = builtins.toFile "abird-kanidm-app-links-data.js" ''
    export const appLinks = ${builtins.toJSON appLinksMetadata};
  '';
  uiHashFiles =
    uiAssets
    // {
      "default.nix" = ./default.nix;
    };
  uiHashInput =
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        dst: src: "${dst}\n${builtins.hashFile "sha256" src}"
      )
      uiHashFiles
    )
    + "\napp-links-data\n${builtins.hashString "sha256" (builtins.toJSON appLinksMetadata)}";
  installUiAssets = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      dst: src: ''install -D -m 0644 "${src}" "$out/hpkg/${dst}"''
    )
    uiAssets
  );
  imageBuild = "app-password-ui-${builtins.substring 0 12 (builtins.hashString "sha256" ''
    ${uiHashInput}
  '')}";

  imageName = "localhost/abird/kanidm-server";
  imageTag = "${version}-${imageBuild}";
  imageRef = "${imageName}:${imageTag}";

  upstreamImage = dockerTools.pullImage {
    imageName = "kanidm/server";
    imageDigest = "sha256:cb33c84cb69bf15da5a58ddc866c641ec7ed768a6df68c3b99b069927ddcc431";
    finalImageName = "kanidm/server";
    finalImageTag = version;
    hash = "sha256-jSjuBVOtAQYgOtE7WVWVmMdhB8pM3+moNvJnwRbZOJ8=";
  };

  uiLayer = stdenvNoCC.mkDerivation {
    pname = "kanidm-server-app-password-ui-layer";
    inherit version;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      ${installUiAssets}
      install -D -m 0644 ${appLinksData} "$out/hpkg/app-links-data.js"
      substituteInPlace "$out/hpkg/style.js" \
        --replace-fail "@abirdUiVersion@" "${imageBuild}"
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
        "com.kanidm.git-commit" = "7e087f6edd9ec5bf3877d6b8fee4b26fbc3d0d6f";
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
      upstreamImageDigest = "sha256:cb33c84cb69bf15da5a58ddc866c641ec7ed768a6df68c3b99b069927ddcc431";
    };

    meta = {
      description = "Kanidm server image with Abird app password UI";
      homepage = "https://github.com/kanidm/kanidm";
      license = lib.licenses.mpl20;
      platforms = lib.platforms.linux;
    };
  }
