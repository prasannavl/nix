{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  pname = "stalwart-cli";
  version = "1.0.8";
  platform = stdenvNoCC.hostPlatform.system;
  release =
    {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-PZE6eoHxNkAczQml1FUQb2dVzbqLaca5NIRfIMNa1KY=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-fqP7v2czeVBPuJgd6W1Er2ZNRndn23XkhBfyBNYtGUk=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-jLdXaCxzvs7yC/rp1AVODLpxazUq2yVuWPCpSqoUGsM=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-q25seOD2Y4hw65x/LVg9Mc0I9th8xlH6NWs5I28HRrY=";
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
