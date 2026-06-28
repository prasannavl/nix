{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  pname = "stalwart-cli";
  version = "1.0.9";
  platform = stdenvNoCC.hostPlatform.system;
  release =
    {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-32bHf7qLlX6ttRZNbtdW+3/rkol2DrUKNUdrrDdgM70=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-sTMGWC0U0uzjhdB2rY9CCU42f5QTDt/28QmYuUyrYtw=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-20uuxMns0fLlsPZWJzx2TUHNkLPRa4+g49/e7gUkuVs=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-aOnoIr502o6l5UyP06qbQL6VTtbmytX05u+CI81muUw=";
      };
    }.${
      platform
    };
in
  stdenvNoCC.mkDerivation {
    inherit pname version;

    src = fetchurl {
      url = "https://github.com/stalwartlabs/cli/releases/download/v${version}/stalwart-cli-${release.target}.tar.xz";
      hash = release.hash;
    };

    sourceRoot = "stalwart-cli-${release.target}";

    installPhase = ''
      runHook preInstall
      install -Dm755 stalwart-cli $out/bin/stalwart-cli
      runHook postInstall
    '';

    meta = {
      description = "Command-line administration tool for Stalwart";
      homepage = "https://github.com/stalwartlabs/cli";
      license = [lib.licenses.agpl3Only];
      mainProgram = "stalwart-cli";
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    };
  }
