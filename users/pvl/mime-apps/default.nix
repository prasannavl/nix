{
  nixos = {...}: {};

  home = {lib, ...}: let
    apps = rec {
      browsers = rec {
        default = chrome;
        associations = [firefox];
        chrome = "google-chrome.desktop";
        firefox = "firefox.desktop";
      };

      editors = rec {
        default = textEditor;
        associations = [
          code
          zed
          neovim
          textEditor
          writer
        ];
        code = "code.desktop";
        textEditor = "org.gnome.TextEditor.desktop";
        neovim = "nvim.desktop";
        writer = "writer.desktop";
        zed = "dev.zed.Zed.desktop";
      };

      fileManagers = rec {
        default = nautilus;
        associations = [
          nautilus
          ranger
        ];
        nautilus = "org.gnome.Nautilus.desktop";
        ranger = "ranger.desktop";
      };

      images = rec {
        default = loupe;
        associations = [loupe];
        loupe = "org.gnome.Loupe.desktop";
      };

      media = {
        mpv = "mpv.desktop";
      };

      audio = rec {
        default = media.mpv;
        associations = [media.mpv];
      };

      video = rec {
        default = media.mpv;
        associations = [media.mpv];
      };

      misc = {
        claudeCli = "claude-code-url-handler.desktop";
        gsconnect = "org.gnome.Shell.Extensions.GSConnect.desktop";
      };
    };

    mimeGroups = {
      browsers = [
        "text/html"
        "x-scheme-handler/http"
        "x-scheme-handler/https"
      ];

      editors = ["text/plain"];
      fileManagers = ["inode/directory"];
      images = ["image/png"];
      video = [
        "video/mp4"
        "video/x-matroska"
      ];
    };

    autoDefaults =
      lib.concatMapAttrs (
        category: mimes:
          lib.genAttrs mimes (_: [apps.${category}.default])
      )
      mimeGroups;

    autoAssociations =
      lib.concatMapAttrs (
        category: mimes:
          lib.genAttrs mimes (_: apps.${category}.associations)
      )
      mimeGroups;
  in {
    xdg.configFile."mimeapps.list".force = true;
    xdg.dataFile."applications/mimeapps.list".force = true;

    xdg.mimeApps = {
      enable = true;

      # Chosen app for direct opens.
      defaultApplications =
        {
          "application/x-extension-htm" = [apps.browsers.firefox];
          "application/x-extension-html" = [apps.browsers.firefox];
          "application/x-extension-shtml" = [apps.browsers.firefox];
          "application/x-extension-xht" = [apps.browsers.firefox];
          "application/x-extension-xhtml" = [apps.browsers.firefox];
          "application/xhtml+xml" = [apps.browsers.firefox];
          "x-scheme-handler/about" = [apps.browsers.chrome];
          "x-scheme-handler/chrome" = [apps.browsers.firefox];
          "x-scheme-handler/claude-cli" = [apps.misc.claudeCli];
          "x-scheme-handler/unknown" = [apps.browsers.chrome];
        }
        // autoDefaults;

      # Candidate apps shown in open-with menus.
      associations.added =
        {
          "application/x-extension-htm" = [apps.browsers.firefox];
          "application/x-extension-html" = [apps.browsers.firefox];
          "application/x-extension-shtml" = [apps.browsers.firefox];
          "application/x-extension-xht" = [apps.browsers.firefox];
          "application/x-extension-xhtml" = [apps.browsers.firefox];
          "application/xhtml+xml" = [apps.browsers.firefox];
          "x-scheme-handler/chrome" = [apps.browsers.firefox];
          "x-scheme-handler/sms" = [apps.misc.gsconnect];
          "x-scheme-handler/tel" = [apps.misc.gsconnect];
        }
        // autoAssociations;
    };
  };
}
