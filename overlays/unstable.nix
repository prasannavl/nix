{inputs}: _final: prev: let
  unstable = import inputs.unstable {
    inherit (prev.stdenv.hostPlatform) system;
    inherit (prev) config;
  };
in {
  inherit unstable;

  # infra
  inherit (unstable) tailscale;

  # containers
  inherit (unstable) crun;
  inherit (unstable) incus;
  inherit (unstable) incus-lts;
  inherit (unstable) lxc;
  inherit (unstable) lxcfs;

  # sway
  inherit (unstable) sway;
  inherit (unstable) swayidle;
  inherit (unstable) swaylock;
  inherit (unstable) wlroots;
  inherit (unstable) xdg-desktop-portal-wlr;

  # ai tools
  inherit (unstable) codex;
  inherit (unstable) gemini-cli;
  inherit (unstable) claude-code;
  inherit (unstable) github-copilot-cli;
  inherit (unstable) jan;

  # apps
  inherit (unstable) vscode;
}
