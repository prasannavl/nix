{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.115.0";
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
      x86_64-linux = "code-stable-x64-1775600256.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1775600239.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1775600246.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-eDSGfF05h5HPTZNeV9l/SBV+9fIV9iVnommM5P/cGgA=";
      x86_64-darwin = "sha256-gHNXSWjbS+xqxjNYaoE7WSeo1Vf2+au/x68RVObJtp0=";
      aarch64-linux = "sha256-PkZiq6STbt1Rb/g9XKeE3tktcrSRyQn/ah1QQxrOITg=";
      aarch64-darwin = "sha256-T7An1+qkBO2QncPvoyymjerwLwti2/MgwmOJJCb2Nhw=";
      armv7l-linux = "sha256-+KfjkiqMBGg9x/Qnd4FHiW0kw0dIQ56DSGUm8SBTc8o=";
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
    x86_64-linux = "sha256-2CQBU7TfYNO4m1Mf6Q0QXFt8C2txJgcN9kd7wX355J4=";
    x86_64-darwin = "sha256-RWA5qJ3xB+V03IPfMBv9zau6Sk+q/fjjax0BETD0Xqs=";
    aarch64-linux = "sha256-a5zx9lD7kgeqF3YdIhcHzQk3axKJpp9K1KYXzxlCLdQ=";
    aarch64-darwin = "sha256-MQB3Yaie1QrTN94+vF62vmoo+YcV+V5DpF68JEb3FVk=";
    armv7l-linux = "sha256-xTf6p/DkytcqvwGH+GtIBnuTIn/Uw8XdJPdwen+onog=";
  };
  rev = "41dd792b5e652393e7787322889ed5fdc58bd75b";
in
  (pkgs.unstable.vscode.override {
    commandLineArgs = commandLineArgs;
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
