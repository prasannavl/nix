{pkgs, ...}: let
  version = "1.112.0";
  inherit (pkgs.stdenv.hostPlatform) system;
  throwSystem = throw "Unsupported system for vscode-upstream: ${system}";
  plat =
    {
      x86_64-linux = "linux-x64";
      x86_64-darwin = "darwin";
      aarch64-linux = "linux-arm64";
      aarch64-darwin = "darwin-arm64";
      armv7l-linux = "linux-armhf";
    }
    .${
      system
    } or throwSystem;
  srcName =
    {
      x86_64-linux = "code-stable-x64-1773778270.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1773778229.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1773778223.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-VyjqPTyLn8eGh/XS3nn0PMqiAsrL91vDZD6Z9L2oh24=";
      x86_64-darwin = "sha256-3ACtYUblaJs8I1BHHFOSFuAODP0dziXFvd0qdJ/izZ8=";
      aarch64-linux = "sha256-wyiOvHNMuE6SbInYK9vlYVkbdxAlf9/xHa2nKWh8ecc=";
      aarch64-darwin = "sha256-0sOKWswv7M3VCralFt1BAA45JrQyAX4Fr/5imNmcaHA=";
      armv7l-linux = "sha256-hAAuYK7ZQGpAQLE9o8/GF+qHHj0OfT15IXY9cvaKBC0=";
    }
    .${
      system
    } or throwSystem;
  serverPlat = {
    x86_64-linux = "server-linux-x64";
    x86_64-darwin = "server-darwin";
    aarch64-linux = "server-linux-arm64";
    aarch64-darwin = "server-darwin-arm64";
    armv7l-linux = "server-linux-armhf";
  };
  serverName = {
    x86_64-linux = "vscode-server-linux-x64.tar.gz";
    x86_64-darwin = "vscode-server-darwin-x64.zip";
    aarch64-linux = "vscode-server-linux-arm64.tar.gz";
    aarch64-darwin = "vscode-server-darwin-arm64.zip";
    armv7l-linux = "vscode-server-linux-armhf.tar.gz";
  };
  serverHash = {
    x86_64-linux = "sha256-je83XIJD2Ayc4/j05BCUi/0dblVGlLQdDf+u7wfHZgA=";
    x86_64-darwin = "sha256-h4BUINzNbHUyFtmaC/4SVS+JFpCCPCtRDEreovdpbFs=";
    aarch64-linux = "sha256-49slKyZcNlwK2JZP/gR+bVCQzNpYCstOg3hh4tZEWWg=";
    aarch64-darwin = "sha256-QjAFtTzEi0DjUQ1uMLUfLfkDkL9yj2gC8Dc5flPjAro=";
    armv7l-linux = "sha256-xokp5gngfLYK/yBApsHJKjvyzrvIN2F6yPOhtMiHLkg=";
  };
  rev = "07ff9d6178ede9a1bd12ad3399074d726ebe6e43";
in
  pkgs.unstable.vscode.overrideAttrs (old: let
    vscodeServers =
      pkgs.lib.mapAttrs
      (serverSystem: serverArchiveName:
        pkgs.srcOnly {
          name = "${serverArchiveName}-${rev}";
          src = pkgs.fetchurl {
            name = serverArchiveName;
            url = "https://update.code.visualstudio.com/commit:${rev}/${serverPlat.${serverSystem}}/stable";
            hash = serverHash.${serverSystem};
          };
          stdenv = pkgs.stdenvNoCC;
        })
      serverName;
  in {
    inherit rev version;
    passthru =
      old.passthru
      // {
        vscodeVersion = version;
        vscodeServers = vscodeServers;
      };
    src = pkgs.fetchurl {
      name = srcName;
      url = "https://update.code.visualstudio.com/commit:${rev}/${plat}/stable";
      hash = srcHash;
    };
    vscodeServer = vscodeServers.x86_64-linux;
  })
