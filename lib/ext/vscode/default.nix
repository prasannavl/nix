{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.125.1";
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
      x86_64-linux = "code-stable-x64-1781859485.tar.gz";
      aarch64-linux = "code-stable-arm64-1781859529.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-EZ3WDviY6hQJ+wFgq5UI6gn4rmxB0wWLk2rrAH4qsiM=";
      aarch64-linux = "sha256-+NKpwyde29EZOdIk56K2cJRtX2iHB4bxsucaeUjoWpY=";
      aarch64-darwin = "sha256-3jbVy9cfv1qtRInn1G2WYG0fafRp3kqquv04nm597Nw=";
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
    x86_64-linux = "sha256-HbCkA+3Zmb1x1lF6tEYPULxWutNNOgTGKwrCqd4EMOo=";
    aarch64-linux = "sha256-lHUasBYNE5IQq5bd+0poB09In7GzlOus8Ds5Hmkrz9U=";
    aarch64-darwin = "sha256-excm1MTPm4USG20u8mO1TDIX5Fu23bCtvcDB+/VrVnw=";
  };
  rev = "fcf604774b9f2674b473065736ee75077e256353";
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
