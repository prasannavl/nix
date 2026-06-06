{inputs}: _final: prev: let
  wlrootsGit = prev.unstable.wlroots.overrideAttrs (_old: {
    version = "git";
    src = inputs.wlroots-git;
  });
  swayUnwrappedGit =
    (
      prev.unstable.callPackage "${inputs.unstable}/pkgs/by-name/sw/sway-unwrapped/package.nix" {
        wlroots_0_20 = wlrootsGit;
      }
    ).overrideAttrs (_old: {
      version = "git";
      src = inputs.sway-git;
    });
  swayGit = prev.unstable.callPackage "${inputs.unstable}/pkgs/by-name/sw/sway/package.nix" {
    sway-unwrapped = swayUnwrappedGit;
  };
  xdgDesktopPortalWlrGit =
    (
      prev.unstable.callPackage "${inputs.unstable}/pkgs/by-name/xd/xdg-desktop-portal-wlr/package.nix" {}
    ).overrideAttrs (_old: {
      version = "git";
      src = inputs.xdg-desktop-portal-wlr-git;
    });
  xdgDesktopPortalGit =
    (
      prev.unstable.callPackage "${inputs.unstable}/pkgs/development/libraries/xdg-desktop-portal/default.nix" {}
    ).overrideAttrs (old: {
      version = "git";
      src = inputs.xdg-desktop-portal-git;
      doCheck = false;
      patches =
        prev.lib.filter (
          patch:
            !(prev.lib.hasInfix "nix-pkgdatadir-env.patch" (toString patch))
            && !(prev.lib.hasInfix "trash-test.patch" (toString patch))
        )
        old.patches;
      postPatch =
        old.postPatch
        + ''
          substituteInPlace src/xdp-portal-config.c \
            --replace-fail 'portal_dir = g_getenv ("XDG_DESKTOP_PORTAL_DIR");' $'portal_dir = g_getenv ("XDG_DESKTOP_PORTAL_DIR");\n  if (portal_dir == NULL)\n    portal_dir = g_getenv ("NIX_XDG_DESKTOP_PORTAL_DIR");'
        '';
    });
  unstableWithGitSway =
    prev.unstable
    // {
      sway = swayGit;
      wlroots = wlrootsGit;
      xdg-desktop-portal-wlr = xdgDesktopPortalWlrGit;
      "xdg-desktop-portal-git" = xdgDesktopPortalGit;
      "sway-git" = swayGit;
      "wlroots-git" = wlrootsGit;
      "xdg-desktop-portal-wlr-git" = xdgDesktopPortalWlrGit;
    };
in {
  unstable = unstableWithGitSway;

  # sway
  inherit (unstableWithGitSway) sway;
  inherit (unstableWithGitSway) wlroots;
  inherit (unstableWithGitSway) xdg-desktop-portal-wlr;
  inherit
    (unstableWithGitSway)
    xdg-desktop-portal-git
    sway-git
    wlroots-git
    xdg-desktop-portal-wlr-git
    ;
}
