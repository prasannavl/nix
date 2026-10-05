# tmux plugin upstream pins.
# nixpkgs 26.05 + master pin same old revs (checked 2026-10-05) => input bump can't fix.
# overlay owns revs, pattern: overlays/sway.nix; drop entry once nixpkgs catches up.
# only resurrect left; rest of old plugin set -> inlined, see
# .agents/docs/notes/tooling/tmux-plugins-inlined-2026-10.md
# fingers stays from nixpkgs (2.6.2): crystal pkg, binary+shard versions must match.
_final: prev: let
  # overrideAttrs on tmux plugin => rebuild via mkTmuxPlugin (nixpkgs addRtp); only rev attrs needed
  pin = {
    version,
    repo,
    rev,
    hash,
    submodules ? false,
  }: {
    inherit version;
    src = prev.fetchFromGitHub {
      owner = "tmux-plugins";
      inherit repo rev hash;
      fetchSubmodules = submodules;
    };
  };
in {
  tmuxPlugins =
    prev.tmuxPlugins
    // {
      recurseForDerivations = true;

      # XDG_DATA_HOME dir, busybox ps, procfs/program-restore fixes
      resurrect = prev.tmuxPlugins.resurrect.overrideAttrs (_old:
        pin {
          version = "unstable-2023-03-06";
          repo = "tmux-resurrect";
          rev = "cff343cf9e81983d3da0c8562b01616f12e8d548";
          hash = "sha256-2ZM23RQps2XO2OYX9NTZj5yIUZEv4ggYzjrJ9RxxLLg=";
          submodules = true;
        });
    };
}
