{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.126.0";
  inherit (pkgs.stdenv.hostPlatform) system;
  throwSystem = throw "Unsupported system for vscode-upstream: ${system}";
  plat =
    {
      x86_64-linux = "linux-x64";
      aarch64-linux = "linux-arm64";
      aarch64-darwin = "darwin-arm64";
    }
    .${
      system
    } or throwSystem;
  srcName =
    {
      x86_64-linux = "code-stable-x64-1782207956.tar.gz";
      aarch64-linux = "code-stable-arm64-1782207906.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-fj2MxTByiFHl2r5rXN/J1mqG69uRNIvDZDujBG5cIxw=";
      aarch64-linux = "sha256-/Qj9sMbrvTxBGRnWgDSE6FI6M1/mwP1jAQrpWflaDYk=";
      aarch64-darwin = "sha256-7j4u1OuHopC1ih/PGWPaEiS35/xFRZTA6uEB/LXq0ew=";
    }
    .${
      system
    } or throwSystem;
  serverPlat = {
    x86_64-linux = "server-linux-x64";
    aarch64-linux = "server-linux-arm64";
    aarch64-darwin = "server-darwin-arm64";
  };
  serverName = {
    x86_64-linux = "vscode-server-linux-x64.tar.gz";
    aarch64-linux = "vscode-server-linux-arm64.tar.gz";
    aarch64-darwin = "vscode-server-darwin-arm64.zip";
  };
  serverHash = {
    x86_64-linux = "sha256-/WJIxuZy+7t2fOnEm3cg9zPqVFLCppyk5O9qO/1yZ0M=";
    aarch64-linux = "sha256-3mrSGHimutLK4OCSnWycif/aqr/D0YVaYmvXph+8i8A=";
    aarch64-darwin = "sha256-lXUMSWFu8aE74k0NtqYm8UBn1QpCE51+HUWbrTh5F3E=";
  };
  rev = "7e7950df89d055b5a378379db9ee14290772148a";
  # VS Code now vendors ripgrep under @vscode/ripgrep-universal; keep the
  # package patch aligned so search keeps working after upstream updates.
  ripgrepPath =
    {
      x86_64-linux = "resources/app/node_modules/@vscode/ripgrep-universal/bin/linux-x64/rg";
      aarch64-linux = "resources/app/node_modules/@vscode/ripgrep-universal/bin/linux-arm64/rg";
      aarch64-darwin = "Contents/Resources/app/node_modules/@vscode/ripgrep-universal/bin/darwin-arm64/rg";
    }
    .${
      system
    } or throwSystem;
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
    buildInputs =
      (old.buildInputs or [])
      ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.libei
        pkgs.libjpeg8.out
        pkgs.libxtst
        pkgs.pipewire
      ];
    autoPatchelfIgnoreMissingDeps =
      (old.autoPatchelfIgnoreMissingDeps or [])
      ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        "libc.musl-x86_64.so.1"
        "libc.musl-aarch64.so.1"
        "libc.musl-armv7.so.1"
      ];
    postPatch = builtins.replaceStrings ["resources/app/node_modules/@vscode/ripgrep/bin/rg"] [ripgrepPath] (old.postPatch or "");
    vscodeServer = vscodeServers.x86_64-linux;
  })
