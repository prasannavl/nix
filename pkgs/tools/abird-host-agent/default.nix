{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}:
pkgHelper.mkRustDerivation {
  pkgs = pkgs;
  pname = "abird-host-agent";
  version = "0.1.0";
  projectDir = "pkgs/tools/abird-host-agent";
  # Several tests execute freshly published fixture programs. Serial execution
  # avoids overlay-backed Nix sandboxes spuriously returning ETXTBSY.
  testCargoArgs = ["-p" "abird-host-agent" "--" "--test-threads=1"];
  buildAttrs.doCheck = false;
  enableDevShell = true;
  meta = {
    description = "Durable host-local service and migration enforcement agent";
    mainProgram = "abird-host-agent";
    platforms = pkgs.lib.platforms.linux;
  };
}
