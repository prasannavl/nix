# Prebuilt musl release. Building from source pulls ~460 crates plus a
# rust-overlay toolchain newer than nixpkgs'; a poor trade for a pinned CLI.
{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  source = (import ./sources.nix).kache;
  platform = stdenvNoCC.hostPlatform.system;
  release =
    source.releases.${platform}
    or (throw "kache: no release archive for ${platform}");
in
  stdenvNoCC.mkDerivation {
    pname = "kache";
    version = source.version;

    src = fetchurl {
      url = "https://github.com/${source.owner}/${source.repo}/releases/download/${source.tagPrefix}${source.version}/kache-${release.target}.tar.gz";
      inherit (release) hash;
    };

    # tarball has no top-level directory
    sourceRoot = ".";

    # static binaries; nothing to build or strip
    dontBuild = true;
    dontConfigure = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib/kache
      install -m755 kache kache-engine kache-cl kache-clang-cl $out/bin/
      # shim farm marker; mirrors the upstream package layout
      for name in cc c++ gcc g++ clang clang++ cargo rustdoc; do
        ln -s $out/bin/kache $out/lib/kache/$name
      done
      touch $out/lib/kache/.kache-shims
      ln -s lib/kache $out/shims
      runHook postInstall
    '';

    meta = {
      description = "Compiler cache for Rust, C/C++ and CUDA";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.asl20;
      mainProgram = "kache";
      platforms = builtins.attrNames source.releases;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
