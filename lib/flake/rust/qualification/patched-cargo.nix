# Qualification-only backport of upstream Cargo PR #16691. Import explicitly;
# never add this package or an overlay to the regular system package set.
{pkgs}: let
  # Canonical file identity is independent of the host/guest support bundle.
  patch = builtins.path {
    path = ./cargo-dep-info-order-16691.patch;
    name = "cargo-dep-info-order-16691.patch";
  };
  upstreamCommit = "074980c2670522e3bde8acb9a25b40510f78626c";
in
  assert pkgs.lib.assertMsg (pkgs.cargo.version == "1.95.0") "qualification Cargo backport is pinned to 1.95.0; review/remove it when upstream is released";
  assert builtins.hashFile "sha256" patch == "70456cea216404c591604f9ebb693b949ef69a58cbdf52b4e6512073fa3951eb";
    pkgs.cargo.overrideAttrs (previous: {
      patches = (previous.patches or []) ++ [patch];
      passthru =
        (previous.passthru or {})
        // {
          qualificationOnly = true;
          depInfoOrderingUpstreamCommit = upstreamCommit;
          unpatchedCargoDrv = pkgs.cargo.drvPath;
        };
    })
