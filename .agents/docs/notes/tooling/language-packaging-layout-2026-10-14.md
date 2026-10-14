# Language packaging layout — 2026-10-14

The human requested cohesive language ownership and a decision about Rust's
scripts. Implementation stays in both main worktrees, continuing the authorized
Rust-foundation integration. The earlier module-default repair and its check are
preserved. Historical side worktrees, receipts and archived events were
untouched.

## Decision

`lib/flake/pkg-helper.nix` remains the public facade and owns generic package
operations. Rust, Go, Node/web, Python and shell implementations now live in
`lib/flake/{rust,go,nodejs,python,shell}/default.nix`, receiving shared
operations explicitly. Facade composition refuses colliding exports. All 94
public helper names are unchanged; no language detection, extra registry or
empty scaffold was introduced.

Rust planning, compile contexts, member bases, toolchains, exports and Trunk
resources are contained under `lib/flake/rust/`. Generic Rust tests and fixtures
live under `rust/tests/`; repository product integration remains in
`lib/flake/tests/<topology>/`.

The mirror CLI and adjacent trusted validator belong to `rust/mirror/` as actual
export tooling. Optional fixture and VM qualification belongs to
`rust/qualification/`. General formatting, update and operational commands
remain under `scripts/`, following their repository owner. Current imports and
Python checkout-root discovery were updated; there are no old-path wrappers.

Runtime mirror support excludes nested tests, mirror CLI resources and optional
qualification. The VM adapter's explicit support inventory includes all language
factories required by the facade, plus Rust's core dependencies. Abird's
ordinary `Cargo.lock.nix` handling remains in its Rust implementation; optional
closure/base/mirror refusal remains unchanged.

## Validation

- Before/after evaluation preserved all 94 public helper names, and complete
  build/check/formatter derivation identities for five language examples plus
  Nixbot shell packaging.
- Twenty-four Rust member/base/artifact/check identities matched the original
  helper in each repo, using actual pinned Crane and a public three-member
  fixture with an explicit native input. This is construction identity evidence,
  rather than a new compilation or runtime qualification.
- Pvl passed 656 pure assertions and Abird 657 across eight Rust suites. Root
  registration retains the same ten language check names.
- Each repository passed 148 Python tests: eight layout, 59 fixture/product, 28
  freshness and 53 mirror checks. Full mirror checks exercised cached Nix
  exports and proved excluded test/tool resources and symlinks were not read.
- The earlier ten Abird module argument/override checks passed again on both
  Linux architectures after relocation.
- Pvl moved 206 tracked files; Abird moved 209. All retain type and executable
  mode, including exact targets for all six deliberate fixture symlinks.
  Respectively 177 and 180 moved files retain exact bytes. Changes in the other
  moved files update imports, discovery, source boundaries and live guidance.
- Twenty-one representative facade/language/core/tooling files match between
  repos in both bytes and mode. The Abird lock-policy and corresponding test
  divergence remain explicit.
- Changed/core/tooling Nix syntax, formatting, Markdown structure, references
  and caller discovery passed. Statix found no new diagnostics. The original ten
  unused-argument/binding diagnostics remain unchanged after extraction.

- Pvl six-package identity inventory SHA256:
  `701f68ed08ed3c6f4fd7abdb43c99b3c5b6ec33a58e54c5abb9822e3ba30a268`.
- Abird six-package identity inventory SHA256:
  `6d09c30bb2c239fcd0a01c4d007a3ec54b72c822de0f000e57b0bc6c0322c749`.

Implementation validation required no package build, VM run, dependency fetch or
deployment. Successful owned temporary validation files were cleaned up.
Validation imported specific modules directly with offline/no-IFD options,
without using a `path:` flake shortcut.

The human subsequently authorized signed commits and pushes in both primary
`master` worktrees. Publication uses the normal pre-push checks and preserves
historical worktrees and qualification source pins.

## Replay

See [language packaging](../../design-patterns/language-packaging.md) for the
stable ownership rules and `lib/flake/rust/README.md` for current entrypoints.
Earlier qualification pins and immutable mirrors retain their original paths and
tooling. Replay those using matching archived support. New mirrors require a
committed revision containing the new paths and its updated support contract;
the layout validation does not extend earlier runtime proof to newer sources.

## Ownership correction — repository recipes

The human correctly identified that `abird-recipes.nix` contained concrete
repository assumptions. Language grouping alone had left product scenario code
inside the generic library. That placement was corrected in both worktrees.

Original manager/host-agent scenarios now live under
`scripts/qualification/rust/pvl/`; the Abird 24-member scenario lives under
`scripts/qualification/rust/abird/recipes.nix`. The recipe implementations
retain their original bytes. Generic `recipe-vm.nix` requires the caller's
`recipeFile` and `preservedFiles`; generic `recipe-seeds.nix` requires explicit
producers, excluded outputs and extra inputs. Neither imports a repository
scenario. The original manager wrapper preserves its defaults and passthru view.

A layout regression prevents product paths and scenario imports in shared
qualification modules. Seed-selection evaluation matches the original selector
and excludes the tested producer. An injected synthetic recipe generated the
expected two VM cases with 16 CPUs / 16 GiB through a recording test-framework
adapter, without starting a guest. Nix syntax/style and documentation checks
passed. No VM, product build or new runtime qualification was selected.
