{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  fleetRuntimeInputs = with pkgs; [
    age
    cloudflared
    coreutils
    findutils
    gawk
    git
    jq
    getent
    inetutils
    iproute2
    nix
    openssh
    opentofu
    procps
    util-linux
  ];
in
  pkgHelper.mkRustDerivation {
    pkgs = pkgs;
    pname = "abird-host-manager";
    version = "0.1.0";
    projectDir = "pkgs/tools/abird-host-manager";
    deps = ["pkgs/tools/abird-host-agent"];
    nativeCheckInputs = [pkgs.bash pkgs.coreutils pkgs.gitMinimal pkgs.jq pkgs.util-linux];
    # Executable fixtures are published by an isolated writer process so the
    # ordinary parallel Cargo test schedule is safe from ETXTBSY races.
    enableDevShell = true;
    extraPassthru = {fleetRuntimeInputs = fleetRuntimeInputs;};
    buildAttrs = {
      ABIRD_HOST_MANAGER_DEFAULT_AGE_PROGRAM = "${pkgs.age}/bin/age";
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
