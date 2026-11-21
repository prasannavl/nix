{inputs}: _final: prev: let
  unstable = import inputs.unstable {
    inherit (prev.stdenv.hostPlatform) system;
    inherit (prev) config;
  };
in {
  unstable = unstable;

  # containers
  inherit (unstable) crun;
  inherit (unstable) incus;
  inherit (unstable) incus-lts;
  inherit (unstable) lxc;
  inherit (unstable) lxcfs;

  # sway
  inherit (unstable) swayidle;
  inherit (unstable) swaylock;

  # ai tools
  inherit (unstable) codex;
  inherit (unstable) claude-code;
  inherit (unstable) github-copilot-cli;
  inherit (unstable) jan;

  # apps
  inherit (unstable) vscode;
  inherit (unstable) keyd;
  # nixos-26.05 still ships obsidian.desktop with
  # StartupWMClass=md.Obsidian, which does not match the Electron app-id
  # md.obsidian.Obsidian; unstable renamed the entry and fixed the class.
  #
  # electron 43 default -> blank window, main-process rejections
  # `webFrame[...] is not a function`; 45 ok for store 1.14.5 asar and
  # auto-updated 1.15.0 asar. recheck after the next electron bump.
  obsidian = unstable.obsidian.override {electron = unstable.electron_45;};
}
