{
  pkgsPath,
  system ? "x86_64-linux",
}: let
  pkgs = import (builtins.toPath pkgsPath) {system = system;};
  makeProbe = payload:
    pkgs.runCommand "rust-foundation-sandbox-probe-${payload}" {} ''
      test "$NIX_BUILD_TOP" = /build
      test ! -e /etc/qualification-guest-marker
      mkdir -p "$out/bin"
      printf '%s\n' '${payload}' > "$out/payload"
      cat > "$out/bin/sandbox-probe" <<'EOF'
      #!${pkgs.bash}/bin/bash
      printf 'sandbox-probe 1\n'
      EOF
      chmod +x "$out/bin/sandbox-probe"
    '';
  describe = drv: {
    build = drv;
    package = drv;
    mainProgram = "sandbox-probe";
    expectedVersion = "sandbox-probe 1\n";
  };
in {
  baseline = describe (makeProbe "baseline");
  changed = describe (makeProbe "changed");
}
