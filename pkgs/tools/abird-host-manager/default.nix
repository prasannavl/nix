{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  abirdHostAgent ? null,
}: let
  fleetRuntimeInputs = with pkgs; [
    cloudflared
    git
    nix
    openssh
    opentofu
  ];
in
  pkgHelper.mkRustDerivation {
    pkgs = pkgs;
    pname = "abird-host-manager";
    version = "0.1.0";
    projectDir = "pkgs/tools/abird-host-manager";
    # Always keep the dependency directory in this package's source; inherit its
    # artifacts only when the root composition supplies the package (the
    # standalone child-flake build has none).
    deps = ["pkgs/tools/abird-host-agent"];
    internalDeps = pkgs.lib.optional (abirdHostAgent != null) abirdHostAgent;
    # `jq` stays in the check environment only: the service-move fake-nix
    # fixture in src/repository.rs transforms a declared move document with it.
    # It is not a runtime or controller-wrapper input; the target health
    # collector carries holds to Rust instead of parsing JSON in-shell.
    nativeCheckInputs = [pkgs.bash pkgs.coreutils pkgs.gitMinimal pkgs.jq pkgs.util-linux];
    # Executable fixtures are published by an isolated writer process so the
    # ordinary parallel Cargo test schedule is safe from ETXTBSY races.
    enableDevShell = true;
    extraPassthru = {fleetRuntimeInputs = fleetRuntimeInputs;};
    buildAttrs = {
      nativeBuildInputs = [pkgs.makeWrapper];
      postInstall = ''
        if [ -x "$out/bin/abird-host-manager" ]; then
          wrapProgram "$out/bin/abird-host-manager" \
            --prefix PATH : ${pkgs.lib.makeBinPath fleetRuntimeInputs}
        fi

        # Keep the Rust compatibility binary tested in the Cargo suite but do
        # not expose it from this package before the explicit Nixbot cutover.
        rm -f "$out/bin/nixbot"
      '';
      doCheck = false;
    };
    meta = {
      description = "Operator control plane for hosts, data, and migrations";
      mainProgram = "abird-host-manager";
      platforms = pkgs.lib.platforms.linux;
    };
  }
