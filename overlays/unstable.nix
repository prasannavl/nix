{inputs}: final: prev: let
  unstable = import inputs.unstable {
    system = prev.stdenv.hostPlatform.system;
    config = prev.config;
  };
in {
  unstable = unstable;

  # infra
  tailscale = unstable.tailscale;

  # containers
  crun = unstable.crun;
  incus = unstable.incus;
  incus-lts = unstable.incus-lts;
  lxc = unstable.lxc;
  lxcfs = unstable.lxcfs;

  # sway
  sway = unstable.sway;
  swayidle = unstable.swayidle;
  swaylock = unstable.swaylock;
  wlroots = unstable.wlroots;
  xdg-desktop-portal-wlr = unstable.xdg-desktop-portal-wlr;

  # ai tools
  codex = unstable.codex;
  gemini-cli = unstable.gemini-cli;
  claude-code = unstable.claude-code;
  github-copilot-cli = unstable.github-copilot-cli;
  jan = unstable.jan;

  # apps
  vscode = unstable.vscode;
}
