{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}:
pkgHelper.mkRustDerivation {
  pkgs = pkgs;
  pname = "abird-host-manager";
  version = "0.1.0";
  projectDir = "pkgs/tools/abird-host-manager";
  deps = ["pkgs/tools/abird-host-agent"];
  nativeCheckInputs = [pkgs.gitMinimal pkgs.jq];
  # Several tests execute freshly published fixture programs. Serial execution
  # avoids overlay-backed Nix sandboxes spuriously returning ETXTBSY.
  testCargoArgs = ["-p" "abird-host-manager" "--" "--test-threads=1"];
  enableDevShell = true;
  buildAttrs = {
    ABIRD_HOST_MANAGER_DEFAULT_AGE_PROGRAM = "${pkgs.age}/bin/age";
    doCheck = false;
  };
  meta = {
    description = "Operator control plane for hosts, data, and migrations";
    mainProgram = "abird-host-manager";
    platforms = pkgs.lib.platforms.linux;
  };
}
