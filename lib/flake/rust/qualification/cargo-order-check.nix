# Explicit qualification regression: real patched Cargo, independent target
# trees and source-edit invalidation. Never register in ordinary root checks.
{
  pkgs,
  cargo ? import ./patched-cargo.nix {pkgs = pkgs;},
}:
pkgs.runCommand "qualification-cargo-dep-info-order-check" {
  nativeBuildInputs = [cargo pkgs.rustc pkgs.stdenv.cc];
} ''
  mkdir -p project/src "$out"
  cd project
  export CARGO_HOME="$TMPDIR/cargo-home"
  mkdir -p "$CARGO_HOME"
  cat >Cargo.toml <<'MANIFEST'
  [package]
  name = "dep-info-ordering-probe"
  version = "0.1.0"
  edition = "2024"
  MANIFEST
  for index in $(seq 0 7); do
    printf 'pub fn value() -> u32 { %s }\n' "$((index + 1))" >"src/module$index.rs"
    printf 'mod module%s;\n' "$index" >>src/lib.rs
  done
  printf 'pub fn value() -> u32 { ' >>src/lib.rs
  for index in $(seq 0 7); do
    if [ "$index" != 0 ]; then printf ' + ' >>src/lib.rs; fi
    printf 'module%s::value()' "$index" >>src/lib.rs
  done
  printf ' }\n' >>src/lib.rs
  printf 'fn main() { println!("{}", dep_info_ordering_probe::value()); }\n' >src/main.rs
  cargo --version >"$out/cargo-version.txt"
  for attempt in first second; do
    cargo build --release --offline >"$out/$attempt.log" 2>&1 || { cat "$out/$attempt.log"; exit 1; }
    test "$(target/release/dep-info-ordering-probe)" = 36
    find target/release/.fingerprint -type f -name 'dep-*' -exec sha256sum {} + | sort >"$out/$attempt-dep-info.sha256"
    test "$(wc -l <"$out/$attempt-dep-info.sha256")" = 2
    mv target "target-$attempt"
  done
  cmp "$out/first-dep-info.sha256" "$out/second-dep-info.sha256"
  mv target-second target
  printf 'pub fn value() -> u32 { 2 }\n' >src/module0.rs
  cargo build --release --offline >"$out/source-edit.log" 2>&1 || { cat "$out/source-edit.log"; exit 1; }
  test "$(target/release/dep-info-ordering-probe)" = 37
  cat >"$out/result.json" <<'RESULT'
  {"independentDepInfoBytesEqual":true,"sourceEditInvalidated":true,"compiler":"original-rustc","qualificationComplete":false}
  RESULT
''
