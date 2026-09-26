{
  autoPatchelfHook,
  bash,
  bubblewrap,
  fetchurl,
  imagemagick,
  lib,
  libxcb,
  libxkbcommon,
  makeWrapper,
  openbox,
  patchelf,
  pkg-config,
  stdenv,
  stdenvNoCC,
  util-linux,
  xauth,
  xclip,
  xdg-utils,
  xdotool,
  xdpyinfo,
  xprop,
  xvfb,
  xwininfo,
}: let
  source = (import ./sources.nix).agent-workspace-linux;
  platform = stdenvNoCC.hostPlatform.system;
  release = source.releases.${platform};

  # Runtime tools the MCP server resolves through PATH (Xvfb display,
  # window manager, scoped input, screenshots, clipboard, bubblewrap
  # sandboxing, and the setsid daemon helper). Prefixing them keeps the
  # package self-contained instead of relying on host-wide installs.
  runtimeTools = [
    bash
    bubblewrap
    imagemagick
    openbox
    pkg-config
    util-linux
    xauth
    xclip
    xdg-utils
    xdotool
    xdpyinfo
    xprop
    xvfb
    xwininfo
  ];
in
  stdenvNoCC.mkDerivation {
    pname = "agent-workspace-linux";
    version = source.version;

    src = fetchurl {
      url = "https://github.com/${source.owner}/${source.repo}/releases/download/${source.tagPrefix}${source.version}/agent-workspace-linux-${release.target}";
      hash = release.hash;
    };

    dontUnpack = true;

    nativeBuildInputs = [
      autoPatchelfHook
      makeWrapper
      patchelf
    ];

    # The prebuilt release binary links libxcb, libxkbcommon (including its
    # x11 module), and libgcc_s/glibc.
    buildInputs = [
      libxcb
      libxkbcommon
      stdenv.cc.cc.lib
    ];

    installPhase = ''
      runHook preInstall

      install -Dm755 $src $out/bin/agent-workspace-linux

      wrapProgram $out/bin/agent-workspace-linux \
        --prefix PATH : ${lib.makeBinPath runtimeTools} \
        --prefix PKG_CONFIG_PATH : ${lib.getDev libxkbcommon}/lib/pkgconfig

      runHook postInstall
    '';

    meta = {
      description = "Isolated Linux desktop workspaces for AI agents";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "agent-workspace-linux";
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
  }
