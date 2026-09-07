{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.136.1";
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
      x86_64-linux = "code-stable-x64-1788413682.tar.gz";
      aarch64-linux = "code-stable-arm64-1788413840.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-m0pU8NSb6qQT7aE30AxlQaY5MA1HnvysVmrRNBlAkhg=";
      aarch64-linux = "sha256-KqwVTsRSgX6Ix7RSsRDyzbqtAK97zwXvc0OJE2ThDEQ=";
      aarch64-darwin = "sha256-vRWhsmzRC6hJAPe9MPIdUe7yaIKOHhWorB+X+ZYgu+U=";
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
    x86_64-linux = "sha256-MYihsWaHogWVchb/NTndLrGeARcpVVOoi+8FOxIYhHU=";
    aarch64-linux = "sha256-h9R5Ul2eAsITmvgkrDOacRIqmyzqee8Dq7dPD8V01jE=";
    aarch64-darwin = "sha256-sQ5bnLaJ1kYURjQqa7CqNdZ6jMDiYeq73GJ8g0hUep8=";
  };
  rev = "a44adf7f53e00964ab890f9f8758a334f1fc15bc";
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
