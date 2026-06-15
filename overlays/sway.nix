{inputs}: _final: prev: let
  swaySrc = builtins.fetchTree {
    type = "github";
    owner = "swaywm";
    repo = "sway";
    rev = "97c342f9e1e1f6ac640f58d53950d92bc48dd889";
    narHash = "sha256-d1azpQVNuQdUTr5KffV4HmlhQTi5AqvG7mnfvopNKTQ=";
  };
  wlrootsSrc = builtins.fetchTree {
    type = "git";
    url = "https://gitlab.freedesktop.org/wlroots/wlroots";
    rev = "63318d28b1ea86873eeb1023d88e56d57bdd2453";
    narHash = "sha256-YGMXx72kWxQAta0s7dp0/gV08w3OgM+hQc3aoYQUJb8=";
  };
  xdgDesktopPortalWlrSrc = builtins.fetchTree {
    type = "github";
    owner = "emersion";
    repo = "xdg-desktop-portal-wlr";
    rev = "5b047df2492d6772df2089835b579f34ab4048b7";
    narHash = "sha256-R0oeuca9HmgeOkZpFpOwl7M3zZ1+DJgsTVcIxhr7L34=";
  };
  xdgDesktopPortalSrc = builtins.fetchTree {
    type = "github";
    owner = "flatpak";
    repo = "xdg-desktop-portal";
    rev = "89f2f5e3d219bc5fd66a2505ee772b16022e8575";
    narHash = "sha256-MmY5rAk6BsJfn7QrS487e46ohAk2K9J6oSGrbQ+ByUw=";
  };
  wlrootsGit = prev.unstable.wlroots.overrideAttrs (_old: {
    version = "git";
    # src = inputs.wlroots-git;
    src = wlrootsSrc;
  });
  swayUnwrappedGit =
    (
      prev.unstable.callPackage "${inputs.unstable}/pkgs/by-name/sw/sway-unwrapped/package.nix" {
        wlroots_0_20 = wlrootsGit;
      }
    ).overrideAttrs (_old: {
      version = "git";
      # src = inputs.sway-git;
      src = swaySrc;
    });
  swayGit = prev.unstable.callPackage "${inputs.unstable}/pkgs/by-name/sw/sway/package.nix" {
    sway-unwrapped = swayUnwrappedGit;
  };
  xdgDesktopPortalWlrGit =
    (
      prev.unstable.callPackage "${inputs.unstable}/pkgs/by-name/xd/xdg-desktop-portal-wlr/package.nix" {}
    ).overrideAttrs (_old: {
      version = "git";
      # src = inputs.xdg-desktop-portal-wlr-git;
      src = xdgDesktopPortalWlrSrc;
    });
  xdgDesktopPortalGit =
    (
      prev.unstable.callPackage "${inputs.unstable}/pkgs/by-name/xd/xdg-desktop-portal/package.nix" {}
    ).overrideAttrs (old: {
      version = "git";
      # src = inputs.xdg-desktop-portal-git;
      src = xdgDesktopPortalSrc;
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
