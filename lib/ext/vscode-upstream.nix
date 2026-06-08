{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "1.122.1";
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
      x86_64-linux = "code-stable-x64-1780040715.tar.gz";
      x86_64-darwin = "VSCode-darwin.zip";
      aarch64-linux = "code-stable-arm64-1780040736.tar.gz";
      aarch64-darwin = "VSCode-darwin-arm64.zip";
      armv7l-linux = "code-stable-armhf-1780040724.tar.gz";
    }
    .${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "sha256-t26YN3E5XaSJ7gki8nm06hVh4ZvXDEU77M749ZrqfAo=";
      x86_64-darwin = "sha256-jOnwhiDJmU+EqU30wg1+frqDDxJgfngETx414i2YTIg=";
      aarch64-linux = "sha256-8sYanI12qDMPgVG7S0QKLEkU0i/SICkJ5wz/OwhP+i4=";
      aarch64-darwin = "sha256-oXeZZWAvpUn5KItEOR8yX9iQ0Fp6EzXGux0jvYbZqtU=";
      armv7l-linux = "sha256-16cUu1C389edf0aHxXxTLJwjxmpHxM8mv1YFnPDLgP4=";
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
    x86_64-linux = "sha256-7n8KvIYEDYO8qqJjfbuUsgUwCxq9FJ6i/EuDBd1HQDk=";
    x86_64-darwin = "sha256-iBGuHM5ElkSArM7CPb/A0hasUGCNjT+7dt5o4MByvCI=";
    aarch64-linux = "sha256-Gp2kldowXk7OE1yO+gT0o+QgiZkucbOb0BjIF77j4sM=";
    aarch64-darwin = "sha256-ztQnTMssQ86sed0G7tlHmNi/0Sx66MhVts9meIElCo0=";
    armv7l-linux = "sha256-HUfGNnoTGa7yJih1uy7RTnC7Sjqstq/lLY1GrQ4fQXo=";
  };
  rev = "8761a5560cfd65fdd19ce7e2bd18dab5c0a4d84e";
  # VS Code now vendors ripgrep under @vscode/ripgrep-universal; keep the
  # package patch aligned so search keeps working after upstream updates.
  ripgrepPath =
    {
      x86_64-linux = "resources/app/node_modules/@vscode/ripgrep-universal/bin/linux-x64/rg";
      x86_64-darwin = "Contents/Resources/app/node_modules/@vscode/ripgrep-universal/bin/darwin-x64/rg";
      aarch64-linux = "resources/app/node_modules/@vscode/ripgrep-universal/bin/linux-arm64/rg";
      aarch64-darwin = "Contents/Resources/app/node_modules/@vscode/ripgrep-universal/bin/darwin-arm64/rg";
      armv7l-linux = "resources/app/node_modules/@vscode/ripgrep-universal/bin/linux-arm/rg";
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
