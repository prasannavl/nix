# Shared test areas adoption (manifest injection), 2026-09-18

## Authority and frozen boundaries

Adopted the shared test areas refactor from the Abird repository (design
document `.agents/docs/design-patterns/shared-test-areas.md`, byte-adopted here
and there). Target started clean on master at
`51cb72ff1356571aafeb29f1409bc3f60e1c2837`, in sync with origin/master. No
commit, push, or deployment was performed; all changes are staged (new files) or
unstaged (edits) in the main worktree.

## What changed

1. Byte-adopted from the Abird worktree (verified `cmp`-identical, re-verified
   after `nix fmt`):
   - `lib/flake/root.nix`: flake assembly now takes repository composition as
     defaulted injected arguments (`repoChecksFn`, `flakeProfileInputNames`,
     `extraCommonModules`, data paths, `defaultMachineProfileName`), replacing
     the Pvl-hardcoded profile-input table and `abird-host-agent` common module.
   - `lib/flake/default.nix`: `repoChecksFn` merges repository checks after the
     generic library and flake tests; the promoted-checks bridge is gone.
   - `lib/flake/tests/default.nix`: the `cr` app program assertion moved out
     (Pvl product content; re-homed in the identity file).
   - `lib/services/kanidm/tests/README.md`: the Pvl upstream-guide paragraph
     moved out (re-homed in the identity file header).
   - `pkgs/tools/nixbot/tests/test_nixbot.py`: the named-Pvl-topology
     control-plane ordering test moved out (re-homed in a repo-only sibling
     module).
2. New repository-owned files:
   - `lib/flake/repo-checks.nix`: this repository's check composition,
     identity-only (Pvl has no product checks to promote).
   - `lib/flake/tests/pvl.nix`: the repository identity file;
     `pvl-flake-isolated` instantiates the flake library standalone with this
     repository's `repoChecksFn` and asserts the `cr` app program binding
     (codex-wrapper).
   - `pkgs/tools/nixbot/tests/test_nixbot_pvl.py`: repo-only sibling module
     carrying the named topology ordering test; the shared unittest discovery in
     `pkgs/tools/nixbot/tests/default.nix` picks it up automatically.
3. `flake.nix` manifest wiring (repository facts stay in repository-owned
   territory): `repoChecksFn = import ./lib/flake/repo-checks.nix;`, the
   10-entry `flakeProfileInputNames.default` table, and
   `extraCommonModules = [./lib/services/abird-host-agent]`. Data paths and
   `defaultMachineProfileName` intentionally stay at the null defaults: Pvl has
   no service-placement document, service-move directory, or default machine
   profile, so behavior is preserved.
4. Documentation: `.agents/docs/design-patterns/shared-test-areas.md`
   byte-adopted (it documents both repositories' instances), plus the README
   design-patterns entry.

## Validation (against the dirty worktree)

- Checks: attribute names equal the baseline plus `pvl-flake-isolated`; nothing
  removed. `nix build` green for `pvl-flake-isolated` together with the generic
  flake, phase-projection, service-moves, kanidm, and nixbot checks.
- `deployDependencies` JSON identical to the baseline.
- Host derivations are semantically unchanged. The drvPath delta versus the
  pre-change baseline is entirely the clean-tree/dirty-tree artifact:
  `nixos-version`'s `@configurationRevision@` substitutes the commit revision on
  a clean tree and stays unsubstituted (`inputs.self.rev` is null) on a dirty
  tree. Proven by dirty-versus-dirty isolation (these changes stashed, tracked
  dummy modification added): the `pvl-x2` and `pvl-vk` toplevel drvPaths are
  byte-identical with and without these changes, and the full derivation-tree
  diff (etc entries, system-path package list) shows no other content
  difference. Durable lesson: capture drvPath baselines in the same tree mode
  (clean versus dirty) as the comparison target; an untracked file alone does
  not flip the flake source to dirty mode.
- The nixbot helper test (`packages.x86_64-linux.nixbot.tests.helper`) rebuilt
  green with the repo-only sibling module present in its source snapshot; the
  runtime test and the nixbot app are unchanged and green.

## Publication state

All changes staged (five new files: the three repo-owned code files and the two
documents) or unstaged (seven edits: six shared-file adoptions plus the README
entry), uncommitted. Revert:
`git checkout -- flake.nix lib/flake/root.nix
lib/flake/default.nix lib/flake/tests/default.nix
lib/services/kanidm/tests/README.md pkgs/tools/nixbot/tests/test_nixbot.py
.agents/docs/README.md`,
then
`git rm -f --cached lib/flake/repo-checks.nix
lib/flake/tests/pvl.nix pkgs/tools/nixbot/tests/test_nixbot_pvl.py
.agents/docs/design-patterns/shared-test-areas.md`
and remove those files, and delete this note.

## Identity directory split adopted (2026-09-18)

Pvl adopted the reworked identity layout byte-for-byte from the upstream
repository: the flat `lib/flake/tests/pvl.nix` split into
`lib/flake/tests/pvl/default.nix` (aggregator; single import target for
`lib/flake/repo-checks.nix`, now importing `./tests/pvl`) plus
`pvl/flake-isolated.nix` (the `cr` app program assertion, imports bumped to
`../../default.nix` and `../../repo-checks.nix`). The updated
`shared-test-areas.md` was byte-adopted; the `.agents/docs/README.md` entry now
names the identity directory. Pvl carries no service-level identity checks yet;
when one appears it becomes a per-stack file under that service's `tests/` (for
example `lib/services/kanidm/tests/<stack>.nix`), registered through
`repo-checks.nix` and never referenced by the service's shared files.

Validation: `pvl-flake-isolated` builds green; the checks attrset equals the
baseline plus `pvl-flake-isolated`; `pvl-x2` and `pvl-vk` toplevel drvPaths are
unchanged (`7az41lz3f2lk8cbwmidzz0n2q6gl79bg-...`,
`9fdn5pzb36ni2bvp496qwiym8q3cvckg-...`). The shared files this note tracks
(`root.nix`, `lib/flake/default.nix`, `lib/flake/tests/default.nix`, kanidm
README, `test_nixbot.py`) are untouched by this step.

Updated revert for this step:
`git checkout -- lib/flake/repo-checks.nix .agents/docs/README.md .agents/docs/design-patterns/shared-test-areas.md`,
then `git rm --cached -r lib/flake/tests/pvl && rm -r lib/flake/tests/pvl`,
`git checkout -- lib/flake/tests/pvl.nix`.

## Independent review pass (2026-09-18)

A fresh-context reviewer of the port plus a design oracle found no blocking
defects. Fixes applied on their findings:

- The shared nixbot test file gained a non-collected `NixbotScriptMixin` base
  (byte-adopted); the repo-only sibling test_nixbot_pvl.py now builds on it, so
  the ~271-test shared suite runs once instead of twice and the sibling adds
  exactly one test (verified: 272 collected, sibling green).
- Comments corrected: repo-checks.nix names
  `lib/flake/tests/pvl/
  flake-isolated.nix` as its second referencer; the
  identity directory header says one level up; the kanidm README describes both
  identity homes; the flake-isolated header documents the laziness invariant
  behind the repo-checks -> identity -> repo-checks import cycle; the upstream
  acceptance-proof guide permalink is restored in the header.
- The manifest's flakeProfileInputNames comment now states that the assignment
  replaces the shared default wholesale, so the full ten-entry table is
  required.
- Design-doc registration wording (byte-adopted): scoped to identity content,
  structural path policy documented, import cycle and mixin convention recorded.

Revalidation: checks attrset unchanged (44 generic + pvl-flake-isolated),
lib-nixbot builds green, pvl-x2 and pvl-lxc host drvPaths match the gold values
from the port validation.
