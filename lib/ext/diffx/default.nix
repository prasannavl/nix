# Prebuilt release: diffx is not in nixpkgs, and upstream publishes the Linux
# binary directly.
{
  autoPatchelfHook,
  fetchurl,
  lib,
  stdenv,
}: let
  source = (import ./sources.nix).diffx;
  platform = stdenv.hostPlatform.system;
  release =
    source.releases.${platform}
    or (throw "diffx: no release archive for ${platform}");
in
  stdenv.mkDerivation {
    pname = "diffx";
    inherit (source) version;

    src = fetchurl {
      url = "https://github.com/${source.owner}/${source.repo}/releases/download/v${source.version}/diffx-${release.target}.tar.gz";
      inherit (release) hash;
    };

    # Tarball has no top-level directory.
    sourceRoot = ".";

    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [stdenv.cc.cc.lib];

    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 diffx $out/bin/diffx
      runHook postInstall
    '';

    meta = {
      description = "Semantic diff for structured data";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "diffx";
      platforms = builtins.attrNames source.releases;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
