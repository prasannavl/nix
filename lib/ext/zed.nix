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

      desktop_file="$out/share/applications/dev.zed.Zed.desktop"
      rm "$desktop_file"
      cp "${pkgs.zed-editor}/share/applications/dev.zed.Zed.desktop" "$desktop_file"
      substituteInPlace "$desktop_file" \
        --replace-fail "TryExec=zeditor" "TryExec=$out/bin/zeditor" \
        --replace-fail "Exec=zeditor %U" "Exec=$out/bin/zeditor %U" \
        --replace-fail "Exec=zeditor --new %U" "Exec=$out/bin/zeditor --new %U"
    '';
  }
