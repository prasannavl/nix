# Abird Post-c3b Linear Port, 2026-09

## Scope

- Pvl pre-port tip: `c467c5ea06123c7eefca734e6b81432a43a762b0`.
- Previous completed Abird boundary: `c3b359045911f122de43abec2cac242b06bdbc4a`.
- Frozen Pvl `abird/master` tip and Abird local `master` tip:
  `dbe24503986bbd7534ac5432809aca34d86a5037`.
- Abird GitHub `origin/master` tip: `af34c9083dc3b1539cce81e5ec44faeff6cc7ef4`.
- Isolated landing worktree: `worktrees/abird-post-c3b-port-20260908` on
  `codex/abird-post-c3b-port-20260908`.

The earlier audit covered a seven-commit union while Abird's local and tracking
branches diverged. The history was subsequently rewritten into one linear
20-commit range after `c3b35904`. This pass audited that complete linear range,
including the commits already dispositioned under their former object IDs.

At the final freeze, Abird's local `master` was three commits ahead of its
GitHub `origin/master`: `76d63c37`, `d690801c`, and `dbe24503`. Pvl's configured
`abird` remote points at that local repository, so this audit deliberately
includes all three unpublished source commits rather than stopping at the GitHub
tip.

## Follow-up recent-commit audit

The September 8 follow-up fetched both repositories again. Abird local `master`
and Pvl `abird/master` were still `dbe24503`; therefore there were zero new
commits on the source branch after the frozen boundary above. Abird GitHub
`origin/master` was still `af34c908`, leaving the same three unpublished source
commits.

One recent source work branch, `codex/nixbot-builder-adoption-20260908`,
contained five commits not reachable from local `master`. It is not a later
change set: it is the pre-rewrite form of the final three master commits. Its
tip, `91c558f6`, has a byte-and-mode identical complete Git tree to `dbe24503`.
Consequently it introduces no new shared `lib/**` or `pkgs/**` path and requires
no second implementation port. The branch-only commits were dispositioned
individually as follows:

|  # | Commit     | Subject                                               | Final disposition                                                                                                                                                                                                                                                                                                                                      |
| -: | ---------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
|  1 | `5461b409` | `feat(host-manager): add native fleet control`        | Adopted through rewritten master commit `76d63c37`. Its native fleet unit was ported; the intermediate helper/bootstrap lease design was superseded by `2e3eeb59` and was correctly not restored.                                                                                                                                                      |
|  2 | `39634d48` | `docs(nixbot): record staged Rust landing`            | Adopted through byte-identical master commit `d690801c`. Shared root, package, and host-manager documentation was adapted; Abird plans, workstream events, and source-only parity artifacts remain skipped.                                                                                                                                            |
|  3 | `0d2b2924` | `docs(nixbot): record local integration`              | Adopted through the final `dbe24503` documentation unit. Its three changes are Abird plan/workstream closeout records, so no file was copied verbatim into Pvl. The reusable integration result is recorded in Pvl's Rust and builder notes.                                                                                                           |
|  4 | `2e3eeb59` | `fixup! feat(host-manager): add native fleet control` | Cleanly ported through rewritten master commit `76d63c37`. The reusable controller-owned inline build lease, stable `/nix/var/nix` lock inode, dry-activation wait bypass, builder role, Bash changes, native runtime changes, and tests are all already in the port. Pvl inventory, dependency, and health seams retain their documented adaptations. |
|  5 | `91c558f6` | `fixup! docs(nixbot): record local integration`       | Adopted through rewritten master commit `dbe24503`. Shared builder semantics were incorporated in Pvl's builder, capacity, deploy, Rust, and signed-cache design notes; Abird workstream events and source-local validation receipts were skipped.                                                                                                     |

The other new-looking branch, `codex/bulwarkmail-npm-fetch-20260908`, points
directly at `dbe24503` and has no unique commit. Older branch tips were outside
this follow-up's recent boundary and remain governed by their existing ledgers.

The final whole-diff review found one Pvl-specific adaptation gap rather than a
missing Abird hunk. Native fleet honored `healthCheck.ignore` in its verdict but
discarded the ignored failed-unit rows, while the active Bash implementation and
Pvl's canonical contract keep those policy exceptions visible. The native health
report now carries ignored rows separately from failure evidence, emits them as
non-failing progress details, and has regression coverage for an exact ignored
unit remaining visible with a healthy verdict.

## September 9 recent-commit audit

The September 9 refresh initially advanced Abird local `master` and Pvl
`abird/master` from `dbe24503` to `d376cc83`. While the audit was running,
Markdown formatting commit `d8b4d7a8` landed, followed by source-workstream
formatting commit `1fd66b4f`, which became the final frozen source tip. Abird
GitHub `origin/master` then advanced to the same tip. Abird local `master`, its
GitHub tracking branch, and Pvl `abird/master` now converge at `1fd66b4f`.

There is one new functional change after the previous boundary, two formatting
follow-ups, and one sibling duplicate commit object:

|  # | Commit     | Ref                                    | Final disposition                                                                                                                                                                                                                                                                                              |
| -: | ---------- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `d376cc83` | local master history                   | Adopted. `pkgs/ext/bulwarkmail/default.nix` is byte-and-mode exact. The reusable npm-fetch diagnosis and cold fixed-output recovery guidance were adapted into Pvl's existing package and builder notes; Abird hostnames, topology, live deployment receipt, and source-only tooling-note layout were skipped. |
|  2 | `d8b4d7a8` | local master history                   | Adopted through `deno fmt` on the locally adapted README, builder note, package note, and ledger. It has no implementation change and no independent Pvl logical unit.                                                                                                                                         |
|  3 | `1fd66b4f` | local master tip, Pvl `abird/master`   | Skipped. It only replaces inline HTML code tags in Abird's excluded native-fleet `TEST-DISPOSITION.md` workstream artifact; Pvl carries neither that source plan nor a corresponding logical unit.                                                                                                             |
|  4 | `436b4052` | `codex/bulwarkmail-npm-fetch-20260908` | Skipped as a duplicate commit object, not a second change. It has the same parent `dbe24503`, tree `b9d951b8a6cfae235fd50bb7ef07a603f6ab1646`, and stable patch ID `de3060d9e8be7844baf778dd01bfc4deaad0f1f0` as `d376cc83`; only commit metadata differs.                                                     |

The adopted package unit hoists `patches` and `postPatch`, defines
`fetchNpmDeps` explicitly, and applies `NIX_BUILD_CORES = "1"` only to the
fixed-output dependency fetch. `buildNpmPackage` consumes that `npmDeps` output
and retains normal application-build parallelism. The fixed-output hash and
store output remain unchanged.

## Per-commit ledger

|  # | Commit     | Subject                                        | Final disposition                                                                                                                                                                                                                                                                                                                                    |
| -: | ---------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `c16e85f4` | `build: refresh dependencies`                  | Adopted before this session, then partly superseded by Pvl policy. Tailscale remains exact. Pvl retains its NVIDIA `595.91.07` rollback, newer VS Code pin, and repository-owned lock graph instead of copying Abird's root lockfile.                                                                                                                |
|  2 | `2cf06a09` | `docs(plan): derive goals from user intent`    | Skipped. Abird durable-agency product plan only; Pvl has no corresponding product or plan.                                                                                                                                                                                                                                                           |
|  3 | `2a22a5e4` | `fix(agent): harden single-prompt goals`       | Skipped. The app, agent, protocol, web UI, browser tests, and plan history are one absent Abird product vertical; it does not change the shared host agent or host manager.                                                                                                                                                                          |
|  4 | `10a225f0` | `docs(agent): plan phase 3.6 schedules`        | Skipped. Abird exact-schedules product planning only.                                                                                                                                                                                                                                                                                                |
|  5 | `a573cad9` | `fix(incus): harden guest lifecycle`           | Cleanly ported before this session. All six `lib/incus` implementation and test files remain byte-and-mode exact at the source tip.                                                                                                                                                                                                                  |
|  6 | `cb974cda` | `fix(abird-dev): satisfy Incus admission`      | Adopted before this session. Pvl owns the physical `abird-dev` project/profile/pool limits; the absent Abird guest-stack declarations were not copied.                                                                                                                                                                                               |
|  7 | `8a3818ab` | `fix(abird-platform): allow CI cache`          | Adopted before this session. Pvl's parent fabric carries the equivalent narrow TCP 5000 cache reachability; the absent Abird stack module was skipped.                                                                                                                                                                                               |
|  8 | `28cca794` | `docs(incus): record Nest recovery`            | Adopted before this session. Reusable route, admission, storage, cache, and restriction findings live in Pvl's existing Incus notes; Abird topology prose was skipped.                                                                                                                                                                               |
|  9 | `518aaca2` | `docs(hosts): record Gondor CI saturation`     | Adopted. The complete shared physical-host build-triggered reclaim evidence was added to Pvl's `pvl-x2` capacity note. Abird-platform-only prose was skipped.                                                                                                                                                                                        |
| 10 | `d5da301d` | `feat(agent): add exact schedules`             | Skipped. Its server, protocol, desktop, web, browser, and schedule-state implementation is an absent Abird product unit with no separable shared package.                                                                                                                                                                                            |
| 11 | `ef756da5` | `docs(agent): record live schedule deploy`     | Skipped. It records deployment of the absent exact-schedules product vertical.                                                                                                                                                                                                                                                                       |
| 12 | `3b433799` | `test(agent): expose Doctor failures`          | Skipped. The Doctor characterization belongs to the absent Abird application package.                                                                                                                                                                                                                                                                |
| 13 | `c0a2c13c` | `docs(agent): close Phase 3.6`                 | Skipped. Product closeout, plans, and retained workstream evidence only.                                                                                                                                                                                                                                                                             |
| 14 | `0a02c745` | `fix(builder): coordinate builds with GC`      | Adopted. Both builder-role module files, the builder check, and the complete host-agent tree are byte-and-mode exact. Pvl adds the check to its additive test registry and enables the role on `pvl-x2` instead of copying `hosts/abird-ci`.                                                                                                         |
| 15 | `04e863be` | `feat(nixbot)!: harden fleet orchestration`    | Adopted. The generic controller-then-registries ordering, dependency-wave preservation, generation-independent build lease, closure revalidation, and regressions were ported. Pvl's `healthCheck.ignore` and default `deployDepsKey` contracts were retained and integrated. Abird-specific operational prose was adapted into Pvl notes.           |
| 16 | `2331d13f` | `style(docs): format builder lease note`       | Adopted as part of the formatted Pvl builder note; no independent semantic unit.                                                                                                                                                                                                                                                                     |
| 17 | `af34c908` | `style(nixbot): apply shell formatting`        | Adopted in the integrated Bash Nixbot surface; no independent behavior change.                                                                                                                                                                                                                                                                       |
| 18 | `76d63c37` | `feat(host-manager): add native fleet control` | Adopted. Every native fleet source and test file is present. Generic files remain exact; inventory, dependency-key, health-ignore, fixture, current-Clippy, root workspace, and Nix packaging seams are narrowly adapted for Pvl. The compatibility `nixbot` binary remains tested but excluded from the installed package pending explicit cutover. |
| 19 | `d690801c` | `docs(nixbot): record staged Rust landing`     | Adopted in part. Root/package/host-manager documentation and a Pvl-native architecture note record the pre-cutover boundary. Abird plans, workstream events, and source-only parity artifacts were skipped.                                                                                                                                          |
| 20 | `dbe24503` | `docs(nixbot): record local integration`       | Adopted in part. The final controller-owned inline lease and no-bootstrap contract is reflected in the builder, capacity, deploy, and Rust notes. Abird plan/workstream closeout evidence was skipped.                                                                                                                                               |

## Logical units

### Previously converged dependency, Incus, and topology work

Commits `c16e85f4`, `a573cad9`, `cb974cda`, `8a3818ab`, and `28cca794` were
already represented at the Pvl pre-port tip. This pass preserved the six exact
shared Incus files and the deliberate split where Abird owns guest-stack intent
while Pvl owns the physical Incus projects, profiles, pools, routes, and
parent-fabric policy.

### Product-owned agent and schedules vertical

Commits `2cf06a09`, `2a22a5e4`, `10a225f0`, `d5da301d`, `ef756da5`, `3b433799`,
and `c0a2c13c` form one Abird application vertical. Pvl has none of its app,
server-agent, protocol, web, desktop, or workstream-plan consumers. Copying
isolated fragments would create dead packages rather than a reusable library, so
the complete vertical is excluded.

### Physical-host saturation evidence

Commit `518aaca2` extends the already-shared `pvl-x2` capacity incident with the
exact nested-memory, Btrfs page-cache, D-state, and network-recovery evidence.
The follow-up builder root cause and current generation-independent lease model
are recorded adjacent to it.

### Builder GC coordination

Commit `0a02c745`, completed by `dbe24503`, supplies one reusable role:

- shared leases for remote realizations and an invocation-wide controller lease;
- exclusive scheduled and host-agent GC on the stable `/nix/var/nix` inode;
- kernel-owned crash release with no roots, generations, helper bootstrap, or
  stale cleanup state;
- one-derivation builder admission; and
- exact module and characterization coverage.

The reusable implementation is exact. Only registration and host selection are
Pvl-owned adaptations.

### Hardened Bash fleet orchestration

Commits `04e863be`, `2331d13f`, and `af34c908` replace the CI-only preference
with a complete controller-then-registry control-plane unit, preserve all hard
edges in both build and deploy ordering, coordinate remote realization with GC,
and recover a lost lease by revalidating the exact planned closure. The GitHub
workflow now invokes `--control-plane-first`. Pvl-specific exact failed-unit
ignores and deploy-dependency key selection remain first-class contracts.

### Native Rust fleet control

Commit `76d63c37` ports the same fleet workflow into `abird-host-manager fleet`:
selection, repository/workspace handling, build, lease, transport, deploy,
rollback, health, bootstrap, CI, OpenTofu, cleanup, signals, diagnostics, and
compatibility parsing. Root workspace dependencies were added because this
repository did not previously consume `base64` or `sha2` from the host manager.
The staged packaging boundary intentionally keeps the active Bash `nixbot`
command unchanged.

### Operational documentation

Commits `d690801c` and `dbe24503` are adopted only where they document shared
runtime behavior. Product planning and Abird-local workstream history remain
source-owned. Pvl's canonical notes describe its controller/cache host and local
inventory extensions rather than copying Abird hostnames or stale helper-based
bootstrap instructions.

## Parity contract

The current `1fd66b4f` source-tip audit compares regular-file content and
executable mode for every path common to `lib/**` and `pkgs/**`. Of 458 common
paths, 417 are byte-and-mode exact, 41 have intentional content differences, and
none differ in mode. The source has 280 additional paths, all belonging to
excluded Abird product/topology/planning units; the commit-by-commit audit found
no missing reusable builder, Nixbot, Incus, host-agent, or host-manager path.

Restricting the comparison to the 102 `lib/**`/`pkgs/**` paths changed after
`c3b35904`, 62 are exact, 19 are documented adaptations, and 21 are absent by
ownership: four Abird topology files and 17 files from the excluded product
vertical.

The complete common-path divergence list is:

- established Pvl platform policy: `lib/ext/nvidia/default.nix`,
  `lib/ext/vscode/default.nix`, `lib/flake/default.nix`, `lib/flake/root.nix`,
  `lib/flake/tests/default.nix`, `lib/flake/tests/phase-projection.nix`,
  `lib/flake/tests/service-moves.nix`, `lib/hardware.nix`,
  `lib/images/default.nix`, `lib/installer/config/default.nix`,
  `lib/kernel.nix`, `lib/locale.nix`, `lib/network.nix`, `lib/nix.nix`,
  `lib/stacks/default.nix`, `lib/sudo.nix`, `lib/swap-auto.nix`, and
  `lib/systemd.nix`;
- additive Pvl check registration: `lib/tests/default.nix`;
- repository-owned package inventory, documentation, and wiring:
  `pkgs/README.md`, `pkgs/cloudflare-apps/README.md`,
  `pkgs/cloudflare-apps/llmug-hello/README.md`, `pkgs/manifest.nix`, and
  `pkgs/support/nats-streams/default.nix`;
- host-manager documentation and explicit single-binding Nix style:
  `pkgs/tools/abird-host-manager/README.md` and
  `pkgs/tools/abird-host-manager/default.nix`;
- Pvl native inventory/dependency/health adaptations:
  `pkgs/tools/abird-host-manager/src/fleet/health_runtime.rs`,
  `pkgs/tools/abird-host-manager/src/fleet/inventory.rs`,
  `pkgs/tools/abird-host-manager/src/fleet/native.rs`, and
  `pkgs/tools/abird-host-manager/src/fleet/runtime.rs`;
- current-Pvl-Clippy-only source rewrites:
  `pkgs/tools/abird-host-manager/src/instance_backup.rs` and
  `pkgs/tools/abird-host-manager/src/repository.rs`;
- Pvl fixtures, contract coverage, and current-Clippy test rewrites:
  `pkgs/tools/abird-host-manager/tests/fleet_binary.rs`,
  `pkgs/tools/abird-host-manager/tests/fleet_contract.rs`,
  `pkgs/tools/abird-host-manager/tests/fleet_health.rs`,
  `pkgs/tools/abird-host-manager/tests/fleet_host_runtime.rs`,
  `pkgs/tools/abird-host-manager/tests/fleet_native_runtime.rs`,
  `pkgs/tools/abird-host-manager/tests/fleet_repository.rs`, and
  `pkgs/tools/abird-host-manager/tests/fleet_system.rs`; and
- Pvl Bash compatibility and its characterizations:
  `pkgs/tools/nixbot/nixbot.sh` and `pkgs/tools/nixbot/tests/test_nixbot.py`.

The complete six-file host-agent tree and both builder-role files are exact.
Within the new native fleet tree, 26 of 30 source files are exact and four are
Pvl inventory/runtime adaptations; 15 of 22 integration-test files are exact and
seven carry Pvl fixtures, policy visibility, contract coverage, or
current-toolchain formatting.

## Validation

- The September 9 refresh found functional commit `d376cc83`, documentation
  formatting commit `d8b4d7a8`, and excluded workstream-formatting commit
  `1fd66b4f`, then proved branch sibling `436b4052` has the same complete tree
  and stable patch ID as `d376cc83`.
- The one `lib/**`/`pkgs/**` path changed after `dbe24503` is present
  byte-for-byte with mode `100644`; there are no missing or adapted paths in the
  new range.
- The evaluated Bulwarkmail npm-deps derivation has `NIX_BUILD_CORES=1`, retains
  fixed-output hash `sha256-ffXwwvyodHRLpQ0B4M8tJHnes8KtAfX9fLsyZL68+KQ=`, and
  retains output
  `/nix/store/h623q9b7gjwdagn2m6kld9md2nib1lx7-bulwarkmail-1.7.5-npm-deps`.
- `nix build --no-link .#bulwarkmail` passed for the complete application and
  image with import from derivation disabled.
- The September 9 follow-up reran the canonical diff lint against `c467c5ea`
  with import from derivation disabled; all changed root outputs, seven host
  configurations, package checks, and format/lint gates passed.
- The September 8 follow-up fetched source refs and found zero new commits after
  `dbe24503` on local `master` or Pvl `abird/master`.
- The complete trees at recent work-branch tip `91c558f6` and master tip
  `dbe24503` are identical at tree object
  `66e041db921f2279c32a2917d7e4247e6ec61daf`.
- All 67 `lib/**`/`pkgs/**` paths touched by the recent work branch are present:
  51 are byte-and-mode exact, 16 are documented Pvl adaptations, and none are
  missing or mode-divergent.
- The September 8 follow-up reran `bash -n pkgs/tools/nixbot/nixbot.sh` and all
  258 Bash/Python Nixbot characterization tests; both passed.
- The September 8 follow-up reran
  `cargo test -p abird-host-manager --locked -- --test-threads=1`; all 483
  native and existing host-manager tests passed.
- The September 8 follow-up reran current Pvl Clippy for all host-manager
  targets with warnings denied in `nix develop .#full`; it passed.
- Rust formatting and repository Markdown/Nix formatting passed.
- The full repository diff lint passed for all declared systems with import from
  derivation disabled.
- The packaged builder coordination, Nixbot, and host-manager checks passed with
  import from derivation disabled. The follow-up reran the packaged host-manager
  check after the health-policy visibility correction; it passed.
- `pvl-x2` evaluated to a concrete NixOS toplevel derivation with import from
  derivation disabled. Full realization was attempted but the ambient Nix daemon
  lost both configured caches and disconnected; this was an external
  cache/daemon failure after successful evaluation, not an evaluation failure.
- No commit, push, deploy, or persistent live mutation was performed.
