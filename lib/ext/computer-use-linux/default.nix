{
  autoPatchelfHook,
  fetchurl,
  glib,
  gnome-screenshot,
  grim,
  lib,
  libnotify,
  libxkbcommon,
  makeWrapper,
  stdenv,
  stdenvNoCC,
  wtype,
  xdotool,
  ydotool,
}: let
  source = (import ./sources.nix).computer-use-linux;
  platform = stdenvNoCC.hostPlatform.system;
  release = source.releases.${platform};

  # One release asset per binary. The server resolves the COSMIC helper and the
  # activity overlay from its own directory, so all three share $out/bin.
  assets =
    lib.mapAttrs (
      binary: hash:
        fetchurl {
          url = "https://github.com/${source.owner}/${source.repo}/releases/download/${source.tagPrefix}${source.version}/${binary}-${release.target}";
          hash = hash;
        }
    )
    release.hashes;

  installAssets = lib.concatStrings (
    lib.mapAttrsToList (binary: asset: ''
      install -Dm755 ${asset} $out/bin/${binary}
    '')
    assets
  );

  # Desktop helpers the server shells out to: X11/Wayland input, screenshots,
  # completion notifications, and the GNOME AT-SPI bridge toggle.
  runtimeTools = [
    glib
    gnome-screenshot
    grim
    libnotify
    wtype
    xdotool
    ydotool
  ];
in
  stdenvNoCC.mkDerivation {
    pname = "computer-use-linux";
    version = source.version;

    dontUnpack = true;

    nativeBuildInputs = [
      autoPatchelfHook
      makeWrapper
    ];

    # Release binaries link glibc (autoPatchelf repairs the interpreter) and
    # dlopen libxkbcommon at runtime for the keymap preflight.
    buildInputs = [
      libxkbcommon
      stdenv.cc.cc.lib
    ];

    installPhase = ''
      runHook preInstall

      ${installAssets}

      wrapProgram $out/bin/computer-use-linux \
        --prefix PATH : ${lib.makeBinPath runtimeTools} \
        --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath [libxkbcommon]}

      runHook postInstall
    '';

    meta = {
      description = "Rust MCP server and CLI for Linux desktop control";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "computer-use-linux";
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
  }
