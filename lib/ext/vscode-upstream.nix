{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.119.0";
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
      x86_64-linux = "code-stable-x64-1778006615.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1778006632.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1778006626.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-HcZIRGB0y8U5huxXN9jNrhMD0Jjmn+QNUU60EHGduXo=";
      x86_64-darwin = "sha256-mMDxEAt/Lst4ifeczcL+QT8mVVXNk8fDNTM1YHGZ8tY=";
      aarch64-linux = "sha256-o0JV1Vc6utTmJkH9uTSylBsYM3mAfiDIgwg3LUOBWb0=";
      aarch64-darwin = "sha256-8ixVOUe4EcNX/z0jnux1hXOhnG1JuhbssH2BARqU80o=";
      armv7l-linux = "sha256-KxrSOVCdfa4L9RlnHybwGLRciMFwC/COsctX+5nqR/c=";
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
    x86_64-linux = "sha256-FyRpbjxY8PWr8z+ttn1H93ud4raFAJz704Vn38+LYCM=";
    x86_64-darwin = "sha256-fj3RcMqdFyClvWyL3WB3sDLPQqCLgXCPZLG0+bPqVTY=";
    aarch64-linux = "sha256-XS3EQYkqT/9M6VRUKf0vcFDWrCr/oLm647R9S3/QgPE=";
    aarch64-darwin = "sha256-YbVh3Wapya3pRh22qk0HAiOgBT1+2FxbsV68Ga2hqdQ=";
    armv7l-linux = "sha256-KRieEWkw6Yh4XfxuFTItVXbWjYs1J38Yfs27WX5w8wQ=";
  };
  rev = "8b640eef5a6c6089c029249d48efa5c99adf7d51";
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
