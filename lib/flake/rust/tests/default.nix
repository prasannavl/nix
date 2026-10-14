# Shared language-owned checks. Repository integration stays in flake/tests/<topology>.
{pkgs}:
{
  lib-flake-rust-lockfile = import ./lockfile.nix {pkgs = pkgs;};
  lib-flake-rust-source-scope = assert builtins.deepSeq (import ./source-scope.nix {}) true;
    pkgs.runCommand "lib-flake-rust-source-scope-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-export = assert builtins.deepSeq (import ./export.nix) true;
    pkgs.runCommand "lib-flake-rust-export-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-compile-context = assert builtins.deepSeq (import ./compile-context.nix) true;
    pkgs.runCommand "lib-flake-rust-compile-context-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-native-context = assert builtins.deepSeq (import ./native-context.nix {}) true;
    pkgs.runCommand "lib-flake-rust-native-context-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-composition = assert builtins.deepSeq (import ./composition.nix) true;
    pkgs.runCommand "lib-flake-rust-composition-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-bases = assert builtins.deepSeq (import ./bases.nix) true;
    pkgs.runCommand "lib-flake-rust-bases-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-closures = assert builtins.deepSeq (import ./closures.nix) true;
    pkgs.runCommand "lib-flake-rust-closures-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-toolchain = assert builtins.deepSeq (import ./toolchain.nix) true;
    pkgs.runCommand "lib-flake-rust-toolchain-test" {} ''
      touch "$out"
    '';
}
// pkgs.lib.optionalAttrs (pkgs ? craneLib && pkgs.craneLib != null) {
  lib-flake-rust-mirror = assert builtins.deepSeq (import ./mirror.nix {inherit pkgs;}) true;
    pkgs.runCommand "lib-flake-rust-mirror-test" {} ''
      touch "$out"
    '';
  lib-flake-rust-source-scope-real = assert builtins.deepSeq (import ./source-scope.nix {inherit pkgs;}) true;
    pkgs.runCommand "lib-flake-rust-source-scope-real-test" {} ''
      touch "$out"
    '';
}
