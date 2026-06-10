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
  version = "0.16.8";
  rev = "v${version}";
  upstreamCommit = "26f41f8aa78fd6daa4cfc88bb57708a8b93a80be";
  patchHash = builtins.substring 0 12 (builtins.hashString "sha256" ''
    ${builtins.readFile ./bind-auth-dn-template.patch}
    ${builtins.readFile ./imap-starttls-auth.patch}
    ${builtins.readFile ./calendar-mailto-normalization.patch}
    ${builtins.readFile ./calendar-floating-timezone-summary.patch}
    ${builtins.readFile ./calendar-organizer-snapshot-dedupe.patch}
    ${builtins.readFile ./calendar-organizer-cn-from-identity.patch}
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
    hash = "sha256-4097zzxUyHYB4TLFgsF6tKNVUiEX0T8Me+D5Efwv2FE=";
  };

  patches = [
    ./bind-auth-dn-template.patch
    ./imap-starttls-auth.patch
    ./calendar-mailto-normalization.patch
    ./calendar-floating-timezone-summary.patch
    ./calendar-organizer-snapshot-dedupe.patch
    ./calendar-organizer-cn-from-identity.patch
    ./dmarc-without-mail-from-spf.patch
    ./calendar-reply-sender-detection.patch
  ];

  cargoExtraArgs = "--locked -p stalwart";
  commonRustAttrs = {
    pname = "stalwart-server";
    inherit version src;
    cargoHash = "sha256-zo7w+sBG3XTsn2mailsrQWqnwsITBqUITKES/HtnpdM=";
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
    imageDigest = "sha256:154dc1f2895ba8d319817fb37c3c26bac3f3e36e2eb338edcf789a79717a5d49";
    finalImageName = "stalwartlabs/stalwart";
    finalImageTag = "v${version}";
    hash = "sha256-Tmu8p0TcG2IHY6jD0yx7UIQETh863hGBLGwNEQbGORk=";
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
      upstreamImageDigest = "sha256:154dc1f2895ba8d319817fb37c3c26bac3f3e36e2eb338edcf789a79717a5d49";
    };

    meta = {
      description = "Patched Stalwart server image";
      homepage = "https://github.com/stalwartlabs/stalwart";
      license = [lib.licenses.agpl3Only];
      platforms = lib.platforms.linux;
    };
  }
