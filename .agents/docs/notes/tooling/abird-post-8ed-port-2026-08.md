# Abird Post-8ed Port, 2026-08

## Scope

- Pvl baseline: `8760e8553ca0ce0caca24160db1a2662f9c1fe15` on the primary
  `master` worktree.
- Previous shared Abird tip: `8ed010e74e12ddfbf482e4e789f39117b761c092`.
- Frozen Abird primary-worktree tip: `3fcaea2cdd7af64ff229f12dfc0304da943ba6f7`.
- Final Pvl implementation tip: `1b62cb8fdb828b00f1ec6fc0fb084b540be92f2a`.
- Audit window: `8ed010e7..3fcaea2c`, eight commits in source order.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

The source primary worktree was clean and eight commits ahead of Abird's GitHub
`origin/master`, which still named `8ed010e7` when this audit began. Pvl's only
pre-existing modification was the final-tip correction in the preceding port
ledger; it was preserved. Three parallel read-only reviews classified the
complete source window before integration.

## Per-Commit Ledger

|  # | Commit     | Subject                                       | Final disposition                                                                                                                                                                                                                                                                                                       |
| -: | ---------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `12a3ef35` | `feat(nix): add Nix-native service moves`     | Partially adopted: the pure move evaluator, placement admission evaluator, schema-1/2 placement reader, and generic placement test are exact. Pvl root wiring and the move test use local inert/synthetic fixtures. Abird Zulip placements, closeouts, stack migration capsule, and deleted JSON topology were skipped. |
|  2 | `6d8cd2fe` | `feat(host-manager): consume Nix move intent` | Adopted: host-agent placement admission, host-manager Nix move consumption and two-deploy closeout, Nix modules, Rust implementation, and tests are exact. The package README retains Pvl's repository-neutral and disabled-by-default adaptations.                                                                     |
|  3 | `31b1ffe0` | `docs(plan): record Nix-native move work`     | Partially adopted: the generic Nix-native move design is exact and the Pvl native-control note records the local enablement boundary. Abird's phase-projection guide, plan state, and implementation/validation events were skipped.                                                                                    |
|  4 | `01f16700` | `docs(plan): record local integration`        | Skipped: Abird worktree, branch, validation, and local-master integration evidence only.                                                                                                                                                                                                                                |
|  5 | `75418f5e` | `style(docs): apply Markdown formatting`      | Adopted through the final exact generic design blob and formatted Pvl documentation. Formatting of excluded Abird plan/event state was skipped.                                                                                                                                                                         |
|  6 | `60008330` | `style(host-agent): apply shell formatting`   | Cleanly ported through the final exact service-placement preflight blob.                                                                                                                                                                                                                                                |
|  7 | `03216e61` | `style(nix): simplify placement fallback`     | Cleanly ported in the exact final service-placement evaluator.                                                                                                                                                                                                                                                          |
|  8 | `3fcaea2c` | `style(host-agent): document jq quoting`      | Cleanly ported in the exact final service-placement preflight blob.                                                                                                                                                                                                                                                     |

## Logical Port Units

1. Nix move and placement admission:
   - validate high-level move declarations and derive projections, claims,
     affected hosts, and controller exclusions;
   - retain schema-1 placement compatibility while making schema-2 role
     placement canonical; and
   - expose the evaluated move and fleet admission contracts through the root
     flake.
2. Host admission and manager lifecycle:
   - reject stateful placement changes that lack one exact adoption transition;
   - execute only evaluated Nix move intent; and
   - retain the recovery lease through adoption, cleanup deployment, and final
     archive.
3. Documentation and tests:
   - preserve the exact generic architecture document;
   - adapt the move evaluator test to synthetic Pvl-independent topology; and
   - record that Pvl's placement, move, and legacy projection inputs remain null
     until Pvl owns an eligible multi-role service capsule.

## Repository-Owned Exclusions

- Abird `data/service-placements.nix`, its removed JSON predecessor, and any
  active move declaration are operational state, not shared library code.
- `lib/stacks/abird-registry.nix` contains the Abird Zulip migration capsule and
  topology.
- Abird plan/work/event files and local integration receipts remain source
  history.
- Pvl has no migration-enabled service or multi-role placement topology, so
  `servicePlacementFile`, `serviceMoveDirectory`, and `phaseProjectionDirectory`
  remain null by default.

## Shared Review Repair

The packaged host-manager test suite exposed one source-side dependency gap: a
new repository fixture executes `jq`, but the test derivation carried only Git.
Both primary worktrees now add `pkgs.jq` to the package's `nativeCheckInputs`.
The change is byte-identical between Pvl and Abird and the complete
150-library-test plus 51-main-test package suite passes in both repositories.
This repair is newer than the committed Abird tip `3fcaea2c` and must become its
own source commit before a later audit can treat it as a ninth source-window
commit.

## Parity Contract

Thirteen implementation, module, test, Rust, and package files are byte-and-mode
exact against the Abird primary working tree. Pvl adapts only:

- `lib/flake/root.nix`: Pvl inputs, physical-host construction, direct agent
  module import, and null placement/move/projection defaults remain;
- `lib/flake/tests/default.nix`: Pvl's aggregate fixture remains while the move
  check is registered;
- `lib/flake/tests/service-moves.nix`: the complete source behavior is exercised
  with synthetic source, target, and router roles because Pvl has no Abird/Zulip
  stack; and
- `pkgs/tools/abird-host-manager/README.md`: repository-neutral examples and the
  disabled-by-default Pvl boundary remain.

The final working-tree census has 402 paths common under tracked `lib/**` and
`pkgs/**`: 382 are byte-and-mode exact, 20 are intentional Pvl-owned flake,
fixture, hardware, image, installer, kernel, locale, Nix, stack, sudo, systemd,
package-catalog, package-documentation, and NATS adaptations, and there are zero
mode differences.

## Validation

- Alejandra, Deno formatting, Cargo formatting, Bash parsing, Nix parsing, and
  `git diff --check` passed.
- The move and placement evaluators, host-agent module, host-manager controller,
  phase-projection VM, and Nixbot checks built successfully.
- `hostManager.serviceMoves` evaluates to an empty schema-1 contract;
  `servicePlacementAdmission` contains no migration placements or moves; and
  Pvl's controller deploy dependency remains `pvl-x2 = []`.
- The packaged host-manager build, formatter, Clippy, and test checks passed.
  The test suite contains 150 library tests and 51 main-command tests.
- `nix flake check --no-build` passed with import from derivation disabled,
  including all exported checks and seven NixOS configurations.
- The repository no-IFD diff lint passed from `8760e855`, including all seven
  changed-host evaluations.
- Complete `pvl-a1`, `pvl-l5`, and `pvl-x2` system closures built successfully.
- A post-port read-only review found no missing consumer, unsafe enablement,
  imported Abird topology, or parity drift.
- The final refetch found no commit after `3fcaea2c`; Abird's local, tracking,
  and live GitHub `master` refs all reached that tip during the audit. The only
  newer source-tree change is the shared unstaged `jq` test dependency repair.
