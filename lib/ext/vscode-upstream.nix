{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.119.1";
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
      x86_64-linux = "code-stable-x64-1778521324.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1778518603.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1778518602.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-U4i4q30lQ/rPU2BA8wmfH7smIK4I1p4uG7w5diP5AlI=";
      x86_64-darwin = "sha256-mPEDN6BgoscNrvGyhUf/t4lyesAEHjbrhEJxb7o5pBI=";
      aarch64-linux = "sha256-tvf8zTAF852EzJ273RpPoW1Kqp7l+2ms31/Xdo4/hC8=";
      aarch64-darwin = "sha256-8Ayh178Lokyh85+1glKv5Xrfu2crrdO7jwDvaS1ubnQ=";
      armv7l-linux = "sha256-/qr2jlKSCvboWt7GfJwxYLBqT6cIIpt+O6soBZL/RMU=";
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
    x86_64-linux = "sha256-/UTVn35zI5sCoFsq9bTOfwj6vgezr/w0jrh7gVWTvq0=";
    x86_64-darwin = "sha256-l9QjG8Nwe1lN6CRv/F8CfvDI14DpwosacmZqdBKWKoo=";
    aarch64-linux = "sha256-LVrOAsXNZR0m5TpFV/9OeJmBTDhZDsziWZ4gSOWx6tA=";
    aarch64-darwin = "sha256-kMp8FmEhHVg2FFMN/pg+EEqQvuucmPlBRekz0YdWUQ4=";
    armv7l-linux = "sha256-I/5Wp/qwnnm3SrbZfWmoPMFlC3XGTOcSCLgvWHBigfU=";
  };
  rev = "974500e64f0d1cfdf7c9821a2a51c2cb3bf0e561";
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
