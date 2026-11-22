# Prebuilt release: a source build pulls a large Rust dependency set and a
# rust-overlay toolchain, while the release artifacts are the upstream path.
{
  autoPatchelfHook,
  curl,
  fetchurl,
  fzf,
  gh,
  git,
  glab,
  jujutsu,
  lib,
  makeWrapper,
  stdenv,
  wl-clipboard,
  xclip,
  xdg-utils,
  xsel,
  zlib,
}: let
  source = (import ./sources.nix).oyo;
  platform = stdenv.hostPlatform.system;
  release =
    source.releases.${platform}
    or (throw "oyo: no release archive for ${platform}");
  runtimeDeps = [
    curl
    fzf
    gh
    git
    glab
    jujutsu
    wl-clipboard
    xclip
    xdg-utils
    xsel
  ];
in
  stdenv.mkDerivation {
    pname = "oyo";
    inherit (source) version;

    src = fetchurl {
      url = "https://github.com/${source.owner}/${source.repo}/releases/download/v${source.version}/oy-${release.target}.tar.gz";
      inherit (release) hash;
    };

    # Tarball has no top-level directory.
    sourceRoot = ".";

    nativeBuildInputs = [
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = [
      stdenv.cc.cc.lib
      zlib
    ];

    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 oy $out/bin/oy
      wrapProgram $out/bin/oy \
        --suffix PATH : ${lib.makeBinPath runtimeDeps}
      runHook postInstall
    '';

    meta = {
      description = "Terminal code review tool";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "oy";
      platforms = builtins.attrNames source.releases;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
