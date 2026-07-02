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
  version = "1.7.5";
  rev = "de56229ef29cf87f620ad49de397941bf405834f";
  shortRev = builtins.substring 0 12 rev;
  patchHash = builtins.substring 0 12 (builtins.hashString "sha256" ''
    ${builtins.readFile ./calendar-organizer-attendee-shape.patch}
    ${builtins.readFile ./local-geist-fonts.patch}
    ${builtins.readFile ./server-logout-route.patch}
    calendar-organizer-attendee-shape-v1
  '');

  imageName = "localhost/abird/bulwarkmail";
  imageTag = "${version}-calendar-shape-${patchHash}";
  imageRef = "${imageName}:${imageTag}";

  src = fetchFromGitHub {
    owner = "bulwarkmail";
    repo = "webmail";
    inherit rev;
    hash = "sha256-2N9Y4AMMXjXzXU+VWN6cQq0BGpIERfPGJmI0L9WbTtg=";
  };

  patchedApp = buildNpmPackage {
    inherit pname version src;
    nodejs = nodejs_24;
    npmDepsHash = "sha256-ffXwwvyodHRLpQ0B4M8tJHnes8KtAfX9fLsyZL68+KQ=";
    patches = [
      ./calendar-organizer-attendee-shape.patch
      ./local-geist-fonts.patch
      ./server-logout-route.patch
    ];

    NEXT_TELEMETRY_DISABLED = "1";
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
        "ai.abird.patch.calendarOrganizerAttendeeShape" = patchHash;
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
      description = "Bulwark Webmail image with Abird calendar organizer/attendee shape fixes";
      homepage = "https://github.com/bulwarkmail/webmail";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.linux;
    };
  }
