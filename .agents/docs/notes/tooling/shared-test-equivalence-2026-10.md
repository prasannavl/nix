# Shared test equivalence — 2026-10

## Scope

Approved direct-main, staged-only changes on z `8ad96801` and nix `fe22967c`. No
commits, pushes, deployment, live probes or input updates.

- Genericize reusable tests first; only actual repository assertions belong
  under `tests/abird/` or `tests/pvl/`.
- Remove `pi-codex-limit` from both repositories. nix already omitted it; z's
  source record and wrapper are removed. Historical references remain history.
- Keep production host policy in shared implementation files. Keep Tailscale and
  its coupled unstable input held; no other flake/Cargo/workspace policy
  changes.
- Plan-event Markdown follows ordinary formatting/lint. This supersedes earlier
  raw-byte exemptions, not historical content or chronological meaning.

## Changes

- Shared Excalidash fail-closed secret handling and regressions; six Rust lock
  assertions; Stalwart CLI-selection regression; NVIDIA default/override check;
  union of generic registrations.
- Shared route JSON inside the manager package, consumed by Rust and explicitly
  copied into the Bash sandbox. Generic tests no longer parse the private
  ledger.
- Hermetic CI rejection fixture and neutral exact-key fixture shared unchanged.
- Pvl's synthetic nested-parent ordering case generalized into shared
  `test_ordering.py`; no Pvl-only directory remains for that case.
- Bash ownership of the Nixbot entrypoint and Rust compatibility-name exclusion
  promoted out of the Abird suite into shared `test_packaging.py`.
- Root-to-child wrapper coherence promoted into shared
  `test_update_helper_repository.py` and registered in both repositories.
  Approved releases/pins, wrapper count, legacy build policy and private
  workspace membership remain Abird-owned; its stale stable-pin expectation is
  corrected to already-approved `718f670e`, without modifying the lockfile.
- Shared GC tests use explicit synthetic capacities and retain coordination,
  locking, forwarding and override assertions. Both repository defaults are
  separately asserted under `lib/tests/<repository>/`, through owned wiring.
- Real Gap3 Kanidm declaration coverage moves to `tests/abird/gap3.nix`; the
  private Nixbot ledger and its coverage assertion move to `tests/abird/`.
  Imports, discovery, sandbox inputs and registration follow the moves.
- Event-specific formatter ignores, lint exclusions and the obsolete exemption
  regression are removed. Shared `lib-lint-markdown` exercises ordinary docs,
  nested/root plan events, JSON, fix/check modes, Markdown lint and untouched
  raw evidence using the actual tools and formatter script.

## Validation findings

The first z manager sandbox run passed 399 library tests but failed the
transient polling fixture with a broken stdin pipe. Its fake successful submit
never read the submitted JSON; it also injected the drop during pre-submit
lookup rather than polling. The shared fixture now consumes and verifies the
spec, reports the initial job absent, then fails the first post-submit status
and succeeds on retry. Production transport code is unchanged; no failure
classification or assertion was weakened.

A concurrent fetch advanced z's remote-tracking `origin/master` and symbolic
`origin/HEAD` from `1a005f9e` to `64be88c7`. Neither checkout's master nor any
recovery/worktree ref changed; the tracking update was left alone.

## Source and coverage result

| Surface  | Common | Identical | Different |
| -------- | -----: | --------: | --------: |
| lib      |    526 |       517 |         9 |
| pkgs     |    304 |       283 |        21 |
| scripts  |     32 |        32 |         0 |
| overlays |      3 |         1 |         2 |
| Total    |    865 |       833 |        32 |

- 308 generic test/fixture paths in areas present in both repositories match in
  path presence, bytes and Git modes, excluding only repository-prefix subtrees.
- 335 generic Nixbot tests are discovered in both. z additionally retains its
  private ledger assertion: 336 total versus 335 in nix. No duplicated inherited
  cases; the old named-topology behavior is covered by the neutral shared case.
- 23 historical Markdown changes (15 z, 8 nix) are exactly the output of pinned
  Deno 2.8.3 on their HEAD blobs. Original filesystem permissions are preserved.
  Raw `.md.raw` evidence, frozen TSV queues and unrelated untracked notes remain
  unchanged.
- The nine library differences are six retained host-policy implementations,
  repository check composition, installer data and held Tailscale. No generic
  test difference remains. Other package/composition/dependency differences are
  outside this pass; this is not whole-repository or build-output identity.

## Gates

Passed in both repositories:

- `nix --offline fmt` and `nix --offline run .#lint -- --base <original-HEAD>`;
  package-owned Statix/Deadnix; `git diff --cached --check`.
- 15 focused Nix realizations in z; 13 in nix: Rust toolchain, Excalidash,
  Stalwart CLI, NVIDIA, GC/shared and owned defaults, Markdown/no-IFD/temp
  cleanup, wrapper coherence, Nixbot helper/runtime and manager tests. z also
  checks its updater policy and actual Gap3 declaration. Realizations mix fresh
  execution and reused outputs; all manager sandbox tests executed freshly in
  both.
- Manager: 400 library and 72 CLI cases plus integration suites, in Nix
  sandboxes and canonical native runs. Strengthened polling fixture: 100
  additional native executions per repository, using the newly compiled library
  test binary.
- Nixbot sandbox: 336 z / 335 nix; shared discovery: 335 each. Source retains
  all 333 original case names. nix replaces only the old Pvl ordering name with
  its neutral equivalent; two packaging cases are added to both.
- Full support/updater discovery: 158 z / 153 nix. Generic optional-Crane
  behavior remains covered in `test_update_helper_child_refs.py`; the Abird
  residual enumerates its actual wrapper membership, not a different generic
  algorithm.
- Real-tool Markdown tests: 4 each. Excalidash: 8 each. Actual z HEAD helper
  fails the three new secret-generation/empty-value controls; actual nix HEAD
  event exemptions fail the new ordinary formatting regression, as intended.
- Git-aware `nix --offline flake check --all-systems --no-build`, with IFD
  forbidden and no remote builders: 217 z checks (109 x86 Linux / 108 ARM
  Linux), 185 nix checks (93/92); zero checks on each declared Darwin output.
  ARM package derivations were instantiated normally first; no foreign build or
  IFD bypass.
- Shared presence/bytes/Git modes and filesystem modes; test discovery; owned
  staging; original local HEADs, worktrees, held policies, locks, frozen queues,
  raw evidence and protected notes/override. Only the separately recorded remote
  tracking update differs from the ref baseline.

These code gates precede this results-only receipt update, which is formatted
and linted separately. No executable input changed afterward. No VM or live-host
acceptance is claimed.

Incus downgrade/recreation compatibility remains a deployment blocker. Shared
source equality does not establish live transport, rollback or fleet readiness.
