{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}:
pkgHelper.mkRustDerivation {
  pkgs = pkgs;
  pname = "abird-host-agent";
  version = "0.1.0";
  projectDir = "pkgs/tools/abird-host-agent";
  # Executable fixtures are published by an isolated writer process so the
  # ordinary parallel Cargo test schedule is safe from ETXTBSY races.
  buildAttrs.doCheck = false;
  # The transfer tests resolve `rsync` from PATH (`executable_in_path("rsync")`).
  nativeCheckInputs = [pkgs.rsync];
  enableDevShell = true;
  meta = {
    description = "Durable host-local service and migration enforcement agent";
    mainProgram = "abird-host-agent";
    platforms = pkgs.lib.platforms.linux;
  };
}
