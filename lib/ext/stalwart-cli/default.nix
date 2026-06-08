{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  pname = "stalwart-cli";
  version = "1.0.6";
  platform = stdenvNoCC.hostPlatform.system;
  release =
    {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-Ln+fAcSmJmwoLUqfH+ezzEmmdcor4GWancxlrIq6AQM=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-ONUuv5Z/PJ658bz/XISwRrqtp4gQ+kqmORwZj7GikeE=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-5I/5YJBIuyGsT89cul4T3iPD/4VjCDeaq00h+CWAwqM=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-LIUNiWdwZkuScPf8mGKcE8ausN8ecKmopnXRUwLJ6HI=";
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
