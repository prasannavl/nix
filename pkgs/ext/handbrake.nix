{pkgs, ...}:
pkgs.symlinkJoin {
  name = "handbrake-wrapped";
  paths = [pkgs.handbrake];

  nativeBuildInputs = [pkgs.makeWrapper];

  postBuild = ''
    wrapProgram $out/bin/HandBrakeCLI \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
    wrapProgram $out/bin/ghb \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
  '';
}
