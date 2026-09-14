{
  pkgs,
  lib,
}: let
  # The kilo-code VS Code extension ships a pre-built standalone `kilo` binary
  # at share/vscode/extensions/kilocode.kilo-code/bin/kilo. That binary is a
  # self-contained Bun AOT snapshot; it has no nixpkgs build dependency.
  # The nixpkgs-`unstable` `kilo` package (7.3.40) is a full source build of
  # the kilo monorepo (console + agent + gateway, 175 MB output) and fails in
  # the Nix sandbox on vite shebang rewriting of node_modules/.bin/vite.
  # We therefore reuse the pre-built binary and skip the broken source build.
  #
  # Follow the same VS Code version the repo pins (via pkgs.vscode-upstream),
  # so bumping the VS Code pin in lib/ext/vscode/default.nix automatically
  # pulls the matching kilo-code extension (and its bundled CLI).
  ext =
    (
      pkgs.nix-vscode-extensions
      .forVSCodeVersion
      pkgs.vscode-upstream.version
    )
    .vscode-marketplace-release.kilocode.kilo-code;
in
  pkgs.runCommand "kilo-cli" {
    nativeBuildInputs = [pkgs.coreutils];
  } ''
    bin="${ext}/share/vscode/extensions/kilocode.kilo-code/bin"
    mkdir -p "$out/bin"
    cp -a "$bin/." "$out/bin/"
  ''
  // {
    meta = {
      description = "Kilo CLI — prebuilt standalone bun-binary from the kilo-code VS Code extension";
      homepage = "https://kilocode.ai";
      license = lib.licenses.mit;
      mainProgram = "kilo";
    };
  }
