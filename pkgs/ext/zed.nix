{pkgs, ...}: let
  runtimeLibs = with pkgs; [
    libcap
    openssl
    xz
    zlib
    stdenv.cc.cc
  ];
in
  pkgs.symlinkJoin {
    name = "zed-wrapped";
    paths = [pkgs.zed-editor];

    nativeBuildInputs = [pkgs.makeWrapper];

    postBuild = ''
      wrapProgram $out/bin/zeditor \
        --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath runtimeLibs}"
    '';
  }
