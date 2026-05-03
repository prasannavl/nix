{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.118.1";
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
      x86_64-linux = "code-stable-x64-1777474884.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1777474898.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1777474894.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-YF0zu0aqZpGGGaf5uNqaVaL1sMQuEVIzZ1Mczuwnfq4=";
      x86_64-darwin = "sha256-zv6Ryr1wTR9+osEhtAHO4viXAI4pc7Yk47dex622ymg=";
      aarch64-linux = "sha256-Mym9ijieF7jVAyZJ/3sO0Wp5JJ4c+/8psCjxrlEH/ok=";
      aarch64-darwin = "sha256-qLshyr9jGyx5dxUGnf5GftlTSoA1OeAWtIvK1aDxqCQ=";
      armv7l-linux = "sha256-JdyQ+65gJCU8Ye2darRV4Hi0//0imkX56bvc52MNLcM=";
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
    x86_64-linux = "sha256-is+djb3G/Lchc4+rqNgjW5xH6vD+OuHDKH7MBKPAJoA=";
    x86_64-darwin = "sha256-5+B6AARj6vEJhDT2Xu/KLCO0liUjSrgt1/CAmdRsDTQ=";
    aarch64-linux = "sha256-4OX2CIZ/7vw4vm/eXnn3v1UzsUcpq1YuCmbph6ESAJk=";
    aarch64-darwin = "sha256-4KdULp1OpYyl2Syrr2WVDjsrH7VDd0Evuy57bCpWyPQ=";
    armv7l-linux = "sha256-EP6t9PE/dpZHHS3DEQIk9f5pl7FESRUjBprkNBtXN5c=";
  };
  rev = "034f571df509819cc10b0c8129f66ef77a542f0e";
in
  (pkgs.unstable.vscode.override {
    inherit commandLineArgs;
  })
  .overrideAttrs (old: let
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
