{inputs}: final: prev: let
  unstable = import inputs.unstable {
    system = prev.stdenv.hostPlatform.system;
    config = prev.config;
  };
in {
  unstable = unstable;

  vscode = unstable.vscode;
  crun = unstable.crun;
  incus = unstable.incus;
  incus-lts = unstable.incus-lts;
  lxc = unstable.lxc;
  lxcfs = unstable.lxcfs;
  jan = unstable.jan;
  tailscale = unstable.tailscale;
  xdg-desktop-portal-wlr = unstable.xdg-desktop-portal-wlr;
}
