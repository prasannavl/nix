# Revision-owned support source boundary for standalone Rust mirrors.
# These cohesive ownership areas include their resources; this is not a package
# inventory or a certificate of arbitrary Nix/build-time filesystem effects.
{
  version = 1;
  supportSources = ["ab/core"];
  # Tests own deliberate unsafe fixtures; they are not runtime support sources.
  excludeSupportSources = [
    "ab/core/packaging/rust/tests"
    "ab/core/packaging/rust/qualification"
    "ab/core/packaging/rust/mirror/tests"
  ];
}
