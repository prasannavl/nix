---
id: 20261003T073000Z-g4-source-repair-validated
at: 2026-10-03T07:30:00Z
actor: agent:rust-fabric-main
type: validation.completed
subject: repair:closure-base-root-manifest-permissions
tags:
  - area:rust
  - evidence:code-only-repair
  - gate:native-retry-pending
---

# Source-copy repair validated; no second fixture attempt

Source-copy failure and writer/runtime evidence:
`20261003T072200Z-g4-source-copy-failure.md`.

Owner `01a10096-02cb-74c4-80f2-1d2ec202bf1a` repaired
`lib/flake/pkg-helper.nix::constructClosureBase`, both chained/unchained source
producers sharing a script that chmods only existing root Cargo.toml
owner-writable before copying the projected root. No public API,
flags/compiler/writer changes, default flip, opaque admission or DAC_OVERRIDE
workaround. Owner added pure/ actual-library tests and a fixture shell
regression, then stopped before executing validation. MAIN completed formatting
and tests.

New persistent fixture: `lib/flake/tests/fixtures/rust-bases/read-only-root.sh`.
`rust-bases.nix.sourceScriptRegression` embeds the actual helper-generated
source script from fake Crane, then appends the controlled regression. UID 1000
run reproduces old copy EACCES and verifies new v1/v2 copy bytes, inode
stability, root mode 0644, untouched member mode/content 0444 and immutable
input. Only GNU coreutils/Bash, no Cargo/Nix builds or fabricated artifacts.

## Validation and identity boundary

- **104** pure base assertions; **105** cached real base assertions.
- Four cached bare/overlaid x86/ARM contexts each pass **105 base / 36
  composition / 73 native / 131 source-scope** assertions; no
  IFD/network/builds.
- Old snapshot versus repaired helpers: baseline/legacy final identity triples
  unchanged in all four contexts. Explicit default/null final/memberLayer/check
  triples unchanged in recorded native overlay comparison; vendor/full-lock
  unchanged. Base suite also covers null/default identity.
- Opt-in leaf/parent/top/unchained bases, explicit/scoped consumers **change
  actual identities as required** to fix the previously unbuildable source
  command. Historical zero-context identity-preservation claims must not conceal
  this correction; no old handle relabeling or opaque matching.
- Bash syntax/ShellCheck and Alejandra pass. Fixture original 19-file
  source/full lock still hash-identical. No native retry since the failed
  two-second attempt.
- Independent scoped reviewer `01a100a2-4469-74c4-80f2-1d30f8925c0d` found no
  P1/P2, confirmed shared script/test scope and identity implications. No
  edits/builds.

Post-attempt identical-container metadata probe also confirms read-only cgroup
filesystem, CHOWN-only effective capability and no-new-privileges. This protects
external limits; it is not arbitrary Nix/store/resource-effect certification.

## Closeout and remaining gate

Indexed qualification/explicit-base notes, docs index, canonical
plan/materialized work view updated. Successful source-fix scratch created
outside repo by the lane was narrowly moved back into repo tmp and its owned
external parent removed. Private cache/failed source diagnostics retained while
useful for another pilot; no unrelated tmp cleanup or store/image/container
deletion. No live containers remain. Existing 190 staged paths preserved; code
fixes are unstaged; no commits, publication, adoption, host daemon/store output
or shared service changes.

Writer's separate approved tool step succeeded; first fixture failed before
Rust; source repair is now code-only validated. Producer remains
`qualified = false`, `not_proven`; actual G4 inheritance/freshness/semantic/cost
evidence is absent. Seek another approved same-scope offline one-job/core/2
GiB/five-minute retry. Refresh helper snapshot/target metadata and private DB
registration while retaining writer cache; repeat full pruned/cache/containment
checks. No implicit retries, fetches, target/platform expansions or limits
relaxed.
