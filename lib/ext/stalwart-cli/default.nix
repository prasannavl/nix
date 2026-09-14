{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  source = (import ./sources.nix).stalwart-cli;
  pname = "stalwart-cli";
  version = source.version;
  platform = stdenvNoCC.hostPlatform.system;
  release = source.releases.${platform};
in
  stdenvNoCC.mkDerivation {
    inherit pname version;

    src = fetchurl {
      url = "https://github.com/${source.owner}/${source.repo}/releases/download/${source.tagPrefix}${version}/stalwart-cli-${release.target}.tar.xz";
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
