{
  dockerTools,
  lib,
  stdenvNoCC,
  appLinksMetadata ? [],
}: let
  source = (import ./sources.nix).kanidm-server;
  version = source.version;
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
    imageDigest = source.imageDigest;
    finalImageName = "kanidm/server";
    finalImageTag = version;
    hash = source.imageHash;
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
        "com.kanidm.git-commit" = source.upstreamCommit;
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
      upstreamImageDigest = source.imageDigest;
    };

    meta = {
      description = "Kanidm server image with Abird app password UI";
      homepage = "https://github.com/kanidm/kanidm";
      license = lib.licenses.mpl20;
      platforms = lib.platforms.linux;
    };
  }
