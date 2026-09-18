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
(lib/flake/repo-checks.nix, wired from the repository manifest flake.nix)
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
  proof guide (https://github.com/abird-ai/z/blob/829d81ed59b06d6d4500c92c5917facabcc92b26/lib/services/kanidm/tests/README.md). The shared standalone
  authority/browser fixtures remain available here; they are separate from
  the packaged helper and normalization checks.
*/
{pkgs}:
import ./flake-isolated.nix {inherit pkgs;}
