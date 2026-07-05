{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  pname = "stalwart-cli";
  version = "1.0.10";
  platform = stdenvNoCC.hostPlatform.system;
  release =
    {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-0XE81OAJCK8C03LRqeROnfaRgqtcr4SBVX8OsbIupfU=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-veMC8xTH5pMjmaQxe6Wl4KxEV0OV97Q2VpO4hxzNVUE=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-3hBGEv97B7LoY/zr2AhRz1Q2uye/QzjVngsC1S6aA0Q=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-iN1laJ9DZkdhFNnoe6cLwNKRGDhyEDR2KxWmtBUoqs0=";
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
