{
  config,
  lib,
  ...
}: let
  bashrcDir = ./bashrc.d;
  bashrcFiles =
    lib.filterAttrs (_: type: type == "regular")
    (builtins.readDir bashrcDir);
  bashrcLinks = lib.mapAttrs' (
    name: _:
      lib.nameValuePair "bash/bashrc.d/${name}" {
        source = bashrcDir + "/${name}";
      }
  ) bashrcFiles;
in {
  programs.bash = {
    enable = true;
    initExtra = lib.mkAfter ''
      __bashrc_d_dir="${config.xdg.configHome}/bash/bashrc.d"
      if [[ -d "$__bashrc_d_dir" ]]; then
        for file in "$__bashrc_d_dir"/*; do
          if [[ -f "$file" ]]; then
            . "$file"
          fi
        done
      fi
      unset __bashrc_d_dir
    '';
  };

  xdg.configFile = bashrcLinks;
}
