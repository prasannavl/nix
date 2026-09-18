# This repository's check composition: the single repo-owned file through which
# identity checks (topology directories under lib/flake/tests/, per-stack
# files localized with their services) and product check promotions enter
# the shared flake library's checks output. Only repository-owned files
# reference it (the manifest flake.nix and the identity area file
# lib/flake/tests/pvl/flake-isolated.nix); shared files stay
# repository-blind and receive this function as an injected argument with an
# empty default. See .agents/docs/design-patterns/shared-test-areas.md.
{pkgs, ...}: import ./tests/pvl {inherit pkgs;}
