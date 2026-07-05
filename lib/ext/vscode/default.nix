{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.127.0";
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
      x86_64-linux = "code-stable-x64-1782814647.tar.gz";
      aarch64-linux = "code-stable-arm64-1782810933.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-4G+zZ5HJuvdJXUt9wPWqqCVOfRpgpe5D5sfevAXJYrU=";
      aarch64-linux = "sha256-UEkpGlTV/KZ8Qcw/OBOCNDQHblD7gHHloSzM62FvDnw=";
      aarch64-darwin = "sha256-IHu9EwW9/oS2FTr/mB7ugMss5Pku3IyslqFYr4riZyk=";
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
    x86_64-linux = "sha256-JpcbzKdVlfRRKCzG/aDoWEGG7Yg0BcjuqCcg/Nez/9U=";
    aarch64-linux = "sha256-KGZwWhcAnW3aVcrqSh/mMwxjCaoXFng4zy9zz70HcRs=";
    aarch64-darwin = "sha256-s86LffCF4fbDA1RSV001zT9azj+av08XOoNGQEUeOnE=";
  };
  rev = "4fe60c8b1cdac1c4c174f2fb180d0d758272d713";
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
