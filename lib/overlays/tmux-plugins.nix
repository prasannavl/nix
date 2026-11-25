# tmux plugin upstream pins.
# nixpkgs 26.05 + master pin same old revs (checked 2026-10-05) => input bump
# can't fix, so the overlay owns the rev. Drop the entry once nixpkgs catches up.
# `fingers` stays from nixpkgs (2.6.2): crystal pkg, binary+shard versions must
# match.
_final: prev: let
  # overrideAttrs on a tmux plugin => rebuild via mkTmuxPlugin; only rev attrs
  # are needed.
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
