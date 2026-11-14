{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  nativeNix ? pkgs.nix,
  abirdHostAgent ? pkgs.callPackage ../abird-host-agent/default.nix {pkgHelper = pkgHelper;},
}: let
  fleetRuntimeInputs = with pkgs; [
    cloudflared
    git
    nativeNix
    openssh
    opentofu
  ];
  buildNativeAdapter =
    if nativeNix.version == "2.34.9"
    then import ./native {inherit pkgs nativeNix;}
    else null;
in
  pkgHelper.mkRustDerivation {
    pkgs = pkgs;
    pname = "abird-host-manager";
    version = "0.1.0";
    projectDir = "pkgs/tools/abird-host-manager";
    # Root and standalone builds share the same dependency constructor by
    # default. An explicit null disables artifact inheritance, not source deps.
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
    extraPassthru = {
      inherit fleetRuntimeInputs buildNativeAdapter;
      buildNativeNix = nativeNix;
    };
    buildAttrs = {
      nativeBuildInputs = [pkgs.makeWrapper];
      postInstall = ''
        if [ -x "$out/bin/abird-host-manager" ]; then
          # Fixed worker subcommands use the same binary without the caller's
          # PATH/repository wrapper. Never change a captured source profile.
          mkdir -p "$out/libexec"
          ${pkgs.lib.optionalString (buildNativeAdapter != null) ''
          ln -s ${buildNativeAdapter}/lib/libabird-owned-nix.so "$out/libexec/libabird-owned-nix.so"
        ''}
          mv "$out/bin/abird-host-manager" "$out/libexec/abird-host-manager"
          makeWrapper "$out/libexec/abird-host-manager" "$out/bin/abird-host-manager" \
            --inherit-argv0 --prefix PATH : ${pkgs.lib.makeBinPath fleetRuntimeInputs}
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
