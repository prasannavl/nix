{
  fetchFromGitHub,
  vimUtils,
  ...
}: let
  sources = import ./sources.nix;

  mkPlugin = name: extraAttrs: let
    source = sources.${name};
  in
    vimUtils.buildVimPlugin (
      {
        pname = source.pname;
        version = "0-unstable-${source.date}";
        src = fetchFromGitHub {
          inherit (source) owner repo rev hash;
        };
      }
      // extraAttrs
    );
in {
  gitlogdiff-nvim = mkPlugin "gitlogdiff-nvim" {
    nvimSkipModules = ["gitlogdiff.docs"];
  };

  worktrees-nvim = mkPlugin "worktrees-nvim" {};
}
