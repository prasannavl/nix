/*
The Pvl repository identity directory: the single home of all
repository-specific test content.

Per .agents/docs/design-patterns/shared-test-areas.md, the generic checks in
../default.nix and the other shared files one level up stay byte-identical
across repositories, while every check that references Pvl-only products,
named topology, or real-host fixtures consolidates in this directory. Each
area file is named after its generic counterpart (flake-isolated.nix, ...),
so the repository's identity content for an area sits beside that area's
shared synthetic coverage. This default.nix imports the area files and is
the directory's single import target: repository-owned composition
(lib/repo-checks.nix, wired from the repository manifest flake.nix)
imports it exactly once, and the shared files never reference identity
content, so they keep evaluating in repositories without Pvl products. The
checks carry the `pvl-` prefix, so flake check output always shows ownership.

Pvl acceptance notes moved out of shared files by that split:

- `pkgs/tools/nixbot/tests/test_nixbot_pvl.py` is the repo-only sibling module
  of the shared test_nixbot.py and carries the named-Pvl-topology
  control-plane ordering test; it builds on the shared non-collected
  NixbotScriptMixin base (helpers only, no inherited tests), and the shared
  unittest discovery in pkgs/tools/nixbot/tests/default.nix picks it up
  automatically.
- The Abird controller, hosted-browser, and native application acceptance
  proofs belong to the upstream product and are excluded from Pvl. Their
  commands and fixture requirements are retained in the upstream identity
  proof guide (https://github.com/abird-ai/z/blob/829d81ed59b06d6d4500c92c5917facabcc92b26/ab/services/kanidm/tests/README.md). The shared standalone
  authority/browser fixtures remain available here; they are separate from
  the packaged helper and normalization checks.
*/
{
  pkgs,
  crane ? null,
}:
import ./flake-isolated.nix {inherit pkgs;}
// import ./postgres-extensions.nix {inherit pkgs;}
// import ./secrets.nix {inherit pkgs;}
// import ./nix-cache-policy.nix {inherit pkgs;}
// import ./pi-web.nix {pkgs = pkgs;}
// {
  pvl-component-boundaries = import ./component-boundaries.nix {pkgs = pkgs;};
  pvl-external-core-package = import ./external-core-package.nix {pkgs = pkgs;};
  pvl-external-runtime = import ./external-runtime.nix {pkgs = pkgs;};
  pvl-external-services = import ./external-services.nix {pkgs = pkgs;};
  pvl-external-repo = import ./external-repo.nix {pkgs = pkgs;};
  pvl-external-stack = import ./external-stack.nix {pkgs = pkgs;};
  pvl-external-z-consumption = import ./external-z-consumption.nix {pkgs = pkgs;};
  pvl-nixos-core = import ./nixos-core.nix {pkgs = pkgs;};
}
// pkgs.lib.optionalAttrs (crane != null) {
  pvl-child-flake-parity = import ./child-flake-parity.nix {inherit pkgs crane;};
  pvl-rust-toolchain-integration = import ./rust-toolchain-integration.nix {pkgs = pkgs;};
  pvl-rust-base-integration = import ./rust-base-integration.nix {
    # Exercise opt-in layering independently of the repository default.
    pkgs = pkgs.extend (_final: _prev: {rustWorkspaceDeps = true;});
  };
  pvl-rust-composition-integration = import ./rust-composition-integration.nix {
    # Exercise opt-in layering independently of the repository default.
    pkgs = pkgs.extend (_final: _prev: {rustWorkspaceDeps = true;});
  };
  pvl-rust-native-context-integration = import ./rust-native-context-integration.nix {pkgs = pkgs;};
  pvl-external-packages = assert builtins.deepSeq (import ./external-packages.nix {inherit pkgs;}) true;
    pkgs.runCommand "pvl-external-packages-test" {} ''
      touch "$out"
    '';
}
