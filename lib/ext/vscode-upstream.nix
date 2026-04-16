{pkgs, ...}: let
  version = "1.116.0";
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
      x86_64-linux = "code-stable-x64-1776214075.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1776214077.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1776214072.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-zoe2E9xlpAME4QD8IagicbAj71g3cA9XlymQQQMFJLo=";
      x86_64-darwin = "sha256-gKpy6+wkcO+znxLdkGMOetpVyhs3SViQyRtCc6yc5XY=";
      aarch64-linux = "sha256-KQR6zD+3m+OgeICSs3LkWo7kC2OxqF6Xax8BRTa6QYQ=";
      aarch64-darwin = "sha256-VZufcJ/g1LPtlQruUwI8Pe5c8LNiAIUHY5+gNnyaPTQ=";
      armv7l-linux = "sha256-0TxKXKQppxcURimXgC40wmqMgiX3DBMJAMc+qjMQCck=";
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
    x86_64-linux = "sha256-HqcaLktkhw3BoEgyFwnMmP7/vuSl1OXZygrQreKeHnM=";
    x86_64-darwin = "sha256-MMcFz8+2cje6vO/dGQk9zu4WPAjcARU+peFEbiLx1m4=";
    aarch64-linux = "sha256-d3RuzwJ87HXGDYkl7uE1KDn0YQRoXx+IFq36/I+0WNU=";
    aarch64-darwin = "sha256-MFkrl/rbpusFM4qTvEz1RvsZNv7ZTOobNLmxroQ5nYQ=";
    armv7l-linux = "sha256-N1UM9o7ABNnhGPfP4m96/mOG0WZE5eCeMWFap6dQbAU=";
  };
  rev = "560a9dba96f961efea7b1612916f89e5d5d4d679";
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
        inherit vscodeServers;
      };
    src = pkgs.fetchurl {
      name = srcName;
      url = "https://update.code.visualstudio.com/commit:${rev}/${plat}/stable";
      hash = srcHash;
    };
    vscodeServer = vscodeServers.x86_64-linux;
  })
