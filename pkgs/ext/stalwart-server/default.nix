{
  dockerTools,
  fetchFromGitHub,
  lib,
  llvmPackages,
  cmake,
  pkg-config,
  rustPlatform,
  stdenvNoCC,
}: let
  version = "0.16.5";
  rev = "v${version}";
  upstreamCommit = "bdba3f20e15e782a083eb2ac91171c73e3a7f6e9";
  patchHash = builtins.substring 0 12 (builtins.hashString "sha256" ''
    ${builtins.readFile ./bind-auth-dn-template.patch}
    ${builtins.readFile ./imap-starttls-auth.patch}
    ${builtins.readFile ./calendar-mailto-normalization.patch}
    ${builtins.readFile ./calendar-floating-timezone-summary.patch}
    ${builtins.readFile ./calendar-organizer-recipient-filter.patch}
    ${builtins.readFile ./calendar-organizer-self-attendee.patch}
    ${builtins.readFile ./dmarc-without-mail-from-spf.patch}
    ${builtins.readFile ./calendar-reply-sender-detection.patch}
  '');
  imageName = "localhost/abird/stalwart";
  imageTag = "${version}-bind-template-${patchHash}";
  imageRef = "${imageName}:${imageTag}";

  src = fetchFromGitHub {
    owner = "stalwartlabs";
    repo = "stalwart";
    inherit rev;
    hash = "sha256-hlaWB88QRGIT5MdF/PVfREgyjFQlwXWenhavunAMXZ0=";
  };

  server = rustPlatform.buildRustPackage {
    pname = "stalwart-server";
    inherit version src;
    cargoHash = "sha256-AiZNbVJkzpGF0cgLRs0Knm00bLokFHShl15z5sehx/k=";
    patches = [
      ./bind-auth-dn-template.patch
      ./imap-starttls-auth.patch
      ./calendar-mailto-normalization.patch
      ./calendar-floating-timezone-summary.patch
      ./calendar-organizer-recipient-filter.patch
      ./calendar-organizer-self-attendee.patch
      ./dmarc-without-mail-from-spf.patch
      ./calendar-reply-sender-detection.patch
    ];
    buildAndTestSubdir = "crates/main";
    nativeBuildInputs = [
      cmake
      llvmPackages.libclang
      pkg-config
    ];
    LIBCLANG_PATH = "${lib.getLib llvmPackages.libclang}/lib";

    meta = {
      description = "Stalwart Mail and Collaboration Server";
      homepage = "https://github.com/stalwartlabs/stalwart";
      license = [lib.licenses.agpl3Only];
      mainProgram = "stalwart";
      platforms = lib.platforms.linux;
    };
  };

  upstreamImage = dockerTools.pullImage {
    imageName = "stalwartlabs/stalwart";
    imageDigest = "sha256:c435a9b97526205dd0bc46245ae97b960cf4cd7a5f1e411f14f36a9d5fc6efdb";
    finalImageName = "stalwartlabs/stalwart";
    finalImageTag = "v${version}";
    hash = "sha256-AO9+KjkinPd59PkP2RbWJUbEtrnoK1JhXciY3CI6P3U=";
  };

  serverLayer = stdenvNoCC.mkDerivation {
    pname = "stalwart-server-layer";
    inherit version;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -D -m 0755 ${server}/bin/stalwart $out/usr/local/bin/stalwart
      runHook postInstall
    '';
  };

  image = dockerTools.buildImage {
    name = imageName;
    tag = imageTag;
    fromImage = upstreamImage;
    copyToRoot = serverLayer;

    config = {
      Entrypoint = ["/usr/local/bin/stalwart"];
      Cmd = [
        "--config"
        "/etc/stalwart/config.json"
      ];
      WorkingDir = "/var/lib/stalwart";
      User = "stalwart";
      ExposedPorts = {
        "25/tcp" = {};
        "110/tcp" = {};
        "143/tcp" = {};
        "443/tcp" = {};
        "465/tcp" = {};
        "587/tcp" = {};
        "993/tcp" = {};
        "995/tcp" = {};
        "4190/tcp" = {};
        "8080/tcp" = {};
      };
      Volumes = {
        "/etc/stalwart" = {};
        "/var/lib/stalwart" = {};
      };
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/stalwartlabs/stalwart";
        "org.opencontainers.image.revision" = upstreamCommit;
        "org.opencontainers.image.version" = "v${version}";
        "ai.abird.patch.bindAuthDnTemplate" = patchHash;
      };
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
        patchHash
        server
        src
        upstreamCommit
        version
        ;
      upstreamImageDigest = "sha256:c435a9b97526205dd0bc46245ae97b960cf4cd7a5f1e411f14f36a9d5fc6efdb";
    };

    meta = {
      description = "Patched Stalwart server image";
      homepage = "https://github.com/stalwartlabs/stalwart";
      license = [lib.licenses.agpl3Only];
      platforms = lib.platforms.linux;
    };
  }
