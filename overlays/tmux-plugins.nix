# Upstream pins for tmux plugins that nixpkgs does not keep current.
#
# The pinned nixpkgs (26.05) and nixpkgs master still point these plugins at
# commits from 2019-2022 (verified 2026-10-05), so bumping the nixpkgs input
# cannot update them. Following the `overlays/sway.nix` pattern, this overlay
# owns the upstream revisions. Drop an entry once nixpkgs carries the same rev.
_final: prev: let
  # `overrideAttrs` on a tmux plugin rebuilds it from the original
  # `mkTmuxPlugin` attrs (see `addRtp` in nixpkgs' tmux-plugins), so only the
  # revision-dependent attrs need restating here.
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

      # README only; keeps the set uniformly at upstream HEAD.
      pain-control = prev.tmuxPlugins.pain-control.overrideAttrs (_old:
        pin {
          version = "unstable-2021-08-09";
          repo = "tmux-pain-control";
          rev = "32b760f6652f2305dfef0acd444afc311cf5c077";
          hash = "sha256-2VI9w7Naj9OHF3iuV63Ij4QcYhbrtngyJ3GpeyzIKxs=";
        });

      # git searches work from any subdirectory.
      copycat = prev.tmuxPlugins.copycat.overrideAttrs (_old:
        pin {
          version = "unstable-2020-07-24";
          repo = "tmux-copycat";
          rev = "d7f7e6c1de0bc0d6915f4beea5be6a8a42045c09";
          hash = "sha256-2dMu/kbKLI/+kO05+qmeuJtAvvO7k9SSF+o2MHNllFk=";
        });

      # editor binding fix, phrase search support, `@open-editor` fix.
      open = prev.tmuxPlugins.open.overrideAttrs (_old:
        pin {
          version = "unstable-2022-08-22";
          repo = "tmux-open";
          rev = "763d0a852e6703ce0f5090a508330012a7e6788e";
          hash = "sha256-Thii7D21MKodtjn/MzMjOGbJX8BwnS+fQqAtYv8CjPc=";
        });

      # status-format[0]/[1] support and interpolation fixes.
      prefix-highlight = prev.tmuxPlugins.prefix-highlight.overrideAttrs (_old:
        pin {
          version = "unstable-2025-03-01";
          repo = "tmux-prefix-highlight";
          rev = "06cbb4ecd3a0a918ce355c70dc56d79debd455c7";
          hash = "sha256-wkMm2Myxau24E0fbXINPuL2dc8E4ZYe5Pa6A0fWhiw4=";
        });

      # XDG_DATA_HOME resurrect dir, busybox `ps`, procfs/program-restore fixes.
      resurrect = prev.tmuxPlugins.resurrect.overrideAttrs (_old:
        pin {
          version = "unstable-2023-03-06";
          repo = "tmux-resurrect";
          rev = "cff343cf9e81983d3da0c8562b01616f12e8d548";
          hash = "sha256-2ZM23RQps2XO2OYX9NTZj5yIUZEv4ggYzjrJ9RxxLLg=";
          submodules = true;
        });

      # systemd unit install/disable fixes (used by the opt-in systemd start).
      continuum = prev.tmuxPlugins.continuum.overrideAttrs (_old:
        pin {
          version = "unstable-2024-01-20";
          repo = "tmux-continuum";
          rev = "0698e8f4b17d6454c71bf5212895ec055c578da0";
          hash = "sha256-W71QyLwC/MXz3bcLR2aJeWcoXFI/A3itjpcWKAdVFJY=";
        });

      # Docs only; keeps the set uniformly at upstream HEAD.
      logging = prev.tmuxPlugins.logging.overrideAttrs (_old:
        pin {
          version = "unstable-2021-06-10";
          repo = "tmux-logging";
          rev = "b5c5f7b9bc679ca161a442e932d6186da8d3538f";
          hash = "sha256-NTDUXxy0Y0dp7qmcH5qqqENGvhzd3lLrIii5u0lYHJk=";
        });
    };
}
