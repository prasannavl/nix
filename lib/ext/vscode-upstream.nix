{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.120.0";
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
      x86_64-linux = "code-stable-x64-1778618960.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1778618964.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1778618962.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-UQQm6yPTML8l2E/ojkmgjZZdayGVe4Lhlq98z3vdiCs=";
      x86_64-darwin = "sha256-+RuW3PctXg536b17B0ECPRJw18Lllr7sAmEgxCD62c0=";
      aarch64-linux = "sha256-acDR0FNM1Bc+Kz2+5dAB7Vwr0MhGuyLcqRcxK2TrG68=";
      aarch64-darwin = "sha256-VVomU5DMMPcnIBEPX0DTvujqeUSJvwnQE1zVIO+pmpc=";
      armv7l-linux = "sha256-FmLT3QijYCVEvEyhsJHgTVOTojQUYHt8NPBXDr0NXao=";
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
    x86_64-linux = "sha256-96dYU+xdw00yb+nXy5f92sg0GrR9plkamSgm72CqKnM=";
    x86_64-darwin = "sha256-8Lgyz5I4+2ojb9ZehyIJEG/VhNeXl4E6iYcKHl1ROh0=";
    aarch64-linux = "sha256-DfUIVQw8yNlSjDR+bNjsLLsb6xegUEDZNSdTwVziw6w=";
    aarch64-darwin = "sha256-nCii52XPKFKsNlIqj5nyTD2y964/grnmERamfya8Mos=";
    armv7l-linux = "sha256-oSi5GIbXRsJrBpUiXBzx8+AG48VcpvicvCpLOlkxfiE=";
  };
  rev = "0958016b2af9f09bb4257e0df4a95e2f90590f9f";
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
