{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.121.0";
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
      x86_64-linux = "code-stable-x64-1779186414.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1779186419.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1779186409.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-jPJMxBRBRT4R6P4a6eWNMpcOI9ztOZg1xLCQQmPWaCA=";
      x86_64-darwin = "sha256-2ReidWJXYyunW9g0n5kc1nh13rHBrq3iAA0bG2VpRxM=";
      aarch64-linux = "sha256-xLwtsFF1mkpyKbaLcSa6Onl/h9PqkiNzowcFkQLGG4U=";
      aarch64-darwin = "sha256-3XKpLgJDH8CDf7BzIdFG8ApxxeYqh+ZiPzTL/oYMgrc=";
      armv7l-linux = "sha256-B9y0cTrHpPxPqUboim0Js5RJ2TMnpNTmOXPOw8fM1kc=";
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
    x86_64-linux = "sha256-TdffAWOhL1Sl7YpaLsPIbnv/qoYToFvfv7R8kgR4XyI=";
    x86_64-darwin = "sha256-TsyqBnRPwHoCucNis+TsbYaIz1ftKaECGuf/+1WVUX4=";
    aarch64-linux = "sha256-7y7So67rKURR7FJG5bV1ytA00zSHQXMLSfqfVDsZH4Q=";
    aarch64-darwin = "sha256-CteizYNgKgxEGxsQiyjJSIgy8v0J/X8om19MKJ6fmlM=";
    armv7l-linux = "sha256-UxtfSPXUc5oGd1FXnbEVfz6QqeEKWV2cPzOfiV1WUMM=";
  };
  rev = "f6cfa2ea2403534de03f069bdf160d06451ed282";
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
