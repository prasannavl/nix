{
  buildEnv,
  buildNpmPackage,
  dockerTools,
  fetchFromGitHub,
  geist-font,
  lib,
  nodejs_24,
}: let
  pname = "bulwarkmail";
  version = "1.7.3";
  rev = "9db7b6b55f1d81a6a0e8439b371605fac92e2989";
  shortRev = builtins.substring 0 12 rev;
  patchHash = builtins.substring 0 12 (builtins.hashString "sha256" ''
    ${builtins.readFile ./client-imip-sending-flag.patch}
    ${builtins.readFile ./local-geist-fonts.patch}
    ${builtins.readFile ./server-logout-route.patch}
    client-imip-sending-v9
  '');

  imageName = "localhost/abird/bulwarkmail";
  imageTag = "${version}-client-imip-sending-off-${patchHash}";
  imageRef = "${imageName}:${imageTag}";

  src = fetchFromGitHub {
    owner = "bulwarkmail";
    repo = "webmail";
    inherit rev;
    hash = "sha256-8EW1o3lIL/wVmrA4bpP09x6fApsEUKAdZq3+mVidPis=";
  };

  patchedApp = buildNpmPackage {
    inherit pname version src;
    nodejs = nodejs_24;
    npmDepsHash = "sha256-MJ5pwPeHE+zBjvTeGaGG4Ybp7gHDaZAiNBwk6bIKaNg=";
    patches = [
      ./client-imip-sending-flag.patch
      ./local-geist-fonts.patch
      ./server-logout-route.patch
    ];

    NEXT_TELEMETRY_DISABLED = "1";
    NEXT_PUBLIC_ENABLE_CLIENT_IMIP_SENDING = "false";
    GIT_COMMIT = shortRev;

    postPatch = ''
      substituteInPlace package.json \
        --replace-fail '"build": "next build --turbopack"' '"build": "next build --webpack"'

      mkdir -p app/fonts
      cp ${geist-font}/share/fonts/opentype/Geist-Regular.otf app/fonts/Geist-Regular.otf
      cp ${geist-font}/share/fonts/opentype/GeistMono-Regular.otf app/fonts/GeistMono-Regular.otf
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/app
      cp -a public $out/app/public
      cp -a .next/standalone/. $out/app/
      mkdir -p $out/app/.next/static
      cp -a .next/static/. $out/app/.next/static/

      runHook postInstall
    '';
  };

  imageRoot = buildEnv {
    name = "bulwarkmail-image-root";
    paths = [
      nodejs_24
      patchedApp
    ];
    pathsToLink = [
      "/app"
      "/bin"
    ];
  };

  image = dockerTools.buildImage {
    name = imageName;
    tag = imageTag;
    copyToRoot = imageRoot;

    config = {
      Cmd = ["/bin/node" "server.js"];
      Env = [
        "NODE_ENV=production"
        "NEXT_TELEMETRY_DISABLED=1"
        "NEXT_PUBLIC_ENABLE_CLIENT_IMIP_SENDING=false"
        "PORT=3000"
        "HOSTNAME=0.0.0.0"
      ];
      ExposedPorts = {
        "3000/tcp" = {};
      };
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/bulwarkmail/webmail";
        "org.opencontainers.image.revision" = rev;
        "org.opencontainers.image.version" = version;
        "ai.abird.patch.clientImipSending" = patchHash;
      };
      User = "1001:65533";
      WorkingDir = "/app";
    };
  };
in
  image
  // {
    passthru = {
      inherit imageName imageRef imageTag patchHash rev shortRev src version;
    };

    meta = {
      description = "Bulwark Webmail image with client iMIP sending disabled";
      homepage = "https://github.com/bulwarkmail/webmail";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.linux;
    };
  }
