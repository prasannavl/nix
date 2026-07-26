{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  pname = "stalwart-cli";
  version = "1.0.11";
  platform = stdenvNoCC.hostPlatform.system;
  release =
    {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-jJzeq9L6+PoqizJACXpjPs25j765RYfDUTvRe/daFOQ=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-sCVtWsqmALPg5THzSOw+6HCcT0FqUEpTAMV80XEgsZk=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-jeEQB6OEf+7AroIkXDGcAID83CxE5JDrFwXUMcMmGhQ=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-HGd7BWM+YF/6W3mT6Ee8J5JEARlGYVZPchZx0NhtPXs=";
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
