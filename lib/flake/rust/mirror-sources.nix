# Revision-owned support source boundary for standalone Rust mirrors.
# These cohesive ownership areas include their resources; this is not a package
# inventory or a certificate of arbitrary Nix/build-time filesystem effects.
{
  version = 1;
  supportSources = ["lib/flake" "lib/services"];
  # Tests own deliberate unsafe fixtures; they are not runtime support sources.
  excludeSupportSources = [
    "lib/flake/tests"
    "lib/flake/rust/tests"
    "lib/flake/rust/qualification"
    "lib/flake/rust/mirror"
  ];
}
