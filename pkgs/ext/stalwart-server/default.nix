{
  dockerTools,
  fetchFromGitHub,
  craneLib ? null,
  lib,
  llvmPackages,
  cmake,
  pkg-config,
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  rustPlatform,
  stdenvNoCC,
}: let
  version = "0.16.11";
  rev = "v${version}";
  upstreamCommit = "0b520b6334379ac64d2d95a37f53e209c89e9577";
  patchHash = builtins.substring 0 12 (builtins.hashString "sha256" ''
    ${builtins.readFile ./bind-auth-dn-template.patch}
    ${builtins.readFile ./imap-starttls-auth.patch}
    ${builtins.readFile ./calendar-mailto-normalization.patch}
    ${builtins.readFile ./calendar-floating-timezone-summary.patch}
    ${builtins.readFile ./dmarc-without-mail-from-spf.patch}
    ${builtins.readFile ./calendar-imip-method-fallback-policy.patch}
    ${builtins.readFile ./calendar-default-display-name-policy.patch}
    ${builtins.readFile ./calendar-organizer-attendee-export-policy.patch}
    ${builtins.readFile ./calendar-organizer-snapshot-dedupe-policy.patch}
    ${builtins.readFile ./calendar-reply-sender-detection-policy.patch}
    ${builtins.readFile ./calendar-organizer-cn-from-identity-policy.patch}
    ${builtins.readFile ./imap-idle-selected-mailbox-updates.patch}
    ${builtins.readFile ./imap-store-pipeline-sync.patch}
    ${builtins.readFile ./imap-quota-empty-root-compat.patch}
  '');
  imageName = "localhost/abird/stalwart";
  imageTag = "${version}-bind-template-${patchHash}";
  imageRef = "${imageName}:${imageTag}";

  src = fetchFromGitHub {
    owner = "stalwartlabs";
    repo = "stalwart";
    inherit rev;
    hash = "sha256-0A8IjetGV4h4qdpm44eZb0sNQ4abulb2+VUAeYWItT0=";
  };

  patches = [
    ./bind-auth-dn-template.patch
    ./imap-starttls-auth.patch
    ./calendar-mailto-normalization.patch
    ./calendar-floating-timezone-summary.patch
    ./dmarc-without-mail-from-spf.patch
    ./calendar-imip-method-fallback-policy.patch
    ./calendar-default-display-name-policy.patch
    ./calendar-organizer-attendee-export-policy.patch
    ./calendar-organizer-snapshot-dedupe-policy.patch
    ./calendar-reply-sender-detection-policy.patch
    ./calendar-organizer-cn-from-identity-policy.patch
    ./imap-idle-selected-mailbox-updates.patch
    ./imap-store-pipeline-sync.patch
    ./imap-quota-empty-root-compat.patch
  ];

  cargoExtraArgs = "--locked -p stalwart";
  commonRustAttrs = {
    pname = "stalwart-server";
    inherit version src;
    cargoHash = "sha256-OpoQzNNm5JUrnk1tRZL9JUpDQnGH73Lj6SW52gSthl0=";
    nativeBuildInputs = [
      cmake
      llvmPackages.libclang
      pkg-config
    ];
    LIBCLANG_PATH = "${lib.getLib llvmPackages.libclang}/lib";
    preBuild = ''
      export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=8
      export CARGO_PROFILE_RELEASE_LTO=thin
      echo "Stalwart release profile override: codegen-units=$CARGO_PROFILE_RELEASE_CODEGEN_UNITS lto=$CARGO_PROFILE_RELEASE_LTO"
    '';

    meta = {
      description = "Stalwart Mail and Collaboration Server";
      homepage = "https://github.com/stalwartlabs/stalwart";
      license = [lib.licenses.agpl3Only];
      mainProgram = "stalwart";
      platforms = lib.platforms.linux;
    };
  };

  server = pkgHelper.mkCraneRustPackage {
    inherit cargoExtraArgs craneLib rustPlatform;
    attrs = commonRustAttrs;
    finalAttrs = {
      inherit patches;
    };
    fallbackAttrs = {
      inherit patches;
      buildAndTestSubdir = "crates/main";
    };
  };

  upstreamImage = dockerTools.pullImage {
    imageName = "stalwartlabs/stalwart";
    imageDigest = "sha256:5ed90ea664cca8eb0058927b8c528abcb9c2c9990e73ccfd3218606555618082";
    finalImageName = "stalwartlabs/stalwart";
    finalImageTag = "v${version}";
    hash = "sha256-gWBtmPLkrgJTS49Sp5eSzfZYegDFgLLL4KT1s7J7IqY=";
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
      upstreamImageDigest = "sha256:5ed90ea664cca8eb0058927b8c528abcb9c2c9990e73ccfd3218606555618082";
    };

    meta = {
      description = "Patched Stalwart server image";
      homepage = "https://github.com/stalwartlabs/stalwart";
      license = [lib.licenses.agpl3Only];
      platforms = lib.platforms.linux;
    };
  }
