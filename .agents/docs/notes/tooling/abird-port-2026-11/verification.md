# Verification and review

Original audit baseline: `2d9f5d5caefd80c1955b298475289d6bc697649a`. Current
candidate integration base: `e7f3ef479c42c8cfa89668230782809cb3a3fb3e`. Frozen
upstream: `070011e2923ebdb16370bbfbba31876c47584002`.

Independent review and final gates passed on the current integration base.
Canonical formatting, diff lint, no-build flake evaluation and all twenty
focused root builds each exited successfully. Results below identify what
actually ran; no historical source rollout is used as acceptance.

## Main-worktree integration

- Explicit user approval: transfer to main and commit logical units; no push.
- Exact transfer: all 294 paths and modes matched the reviewed patch. All 287
  non-report files and the interface guide remain unchanged; six audit reports
  receive delivery metadata only. Shared-file manifest fingerprints are stable.
- Main `nix fmt` and
  `nix flake check --no-build --option
  allow-import-from-derivation false`
  both passed after transfer. Formatting changed none of the reviewed files.
  Final report-only edits passed Deno and the pinned Markdown linter.
- The complete runtime tests, canonical diff lint and twenty root builds below
  ran on the reviewed snapshot at this same main base. Byte/mode equality
  carries that evidence across the transfer; they were not rerun as a new full
  suite after each commit. No intermediate-commit VM qualification is claimed.
- Each implementation commit's exact staged membership and SSH signature was
  verified. The runtime precedes the strategy frontend, which precedes workflow
  VM registration; feature test registrations are split accordingly.
- [The overview](README.md#main-integration) lists the ten implementation
  commits; this receipt's commit completes the series. The original review
  worktree's staging is retained unchanged. No reverse port or deployment.

## Executed gates

| Gate                                                                     | Result and scope                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix fmt`                                                                | Passed on the final code. Report-only closeout edits were separately formatted and Markdown-linted.                                                                                                                                                                        |
| Canonical diff lint                                                      | Passed after all repairs and the current-main refresh. Includes shared static lints, Terraform lint, seven changed host evaluations and conventional package checks.                                                                                                       |
| `nix flake check --no-build --option allow-import-from-derivation false` | Passed: root outputs, seven NixOS configurations and current-system checks evaluated. This does not build all outputs or execute VMs.                                                                                                                                      |
| Twenty focused root checks                                               | Passed against the current main base in the review worktree via ordinary Nix builds, including exact native adapter/package realization and caller module assertions; names below.                                                                                         |
| Final complete Rust suites                                               | 1,640 top-level tests passed, 4 ignored; nested filtered subprocess invocations not double-counted. Separately executed native cases are below; ignored cases are not silently counted as passes.                                                                          |
| Native admission repair                                                  | 51 backend library tests passed; entry 1, CI 16, strategy 5, actual ABI-dependent admission 2, native filesystem preflight 1 and thin-CI routing 1 passed. Strict all-target Clippy and module evaluation passed.                                                          |
| Bash/Nixbot                                                              | Final implementation suite: 356 passed. Includes actual entrypoint, sparse-PATH selectors, hydration, aliases, help, dry-run and ordinary bootstrap.                                                                                                                       |
| Shared AI                                                                | Seven check derivations evaluated; 3 runtime-file tests and 36 prefetch tests passed. Legacy hosting/consumer projections checked for pvl-a1, pvl-l5 and pvl-x2, without changing policy.                                                                                  |
| Rust helper/tooling                                                      | Eight pure Nix suites, real-Crane assertion sets, cold-source regression routes, 97 Python tests and mocked lint failure/cleanup checks passed.                                                                                                                            |
| OpenDesign                                                               | Exact pinned source hash and zero-fuzz patch application verified; 10 upstream patch tests passed. Independent reviewer ran 14 focused cases. Generic non-null-provider image check is registered; full image was not built here.                                          |
| Graphiti                                                                 | Explicit pinned runner: 7 lightweight + 16 real-core tests passed, including isolated loopback wire binding; unchanged source suite also passed 13/13. Reviewer independently ran 21 non-network cases and binding/runner checks. These overlapping counts are not summed. |
| Cloudflare                                                               | Four isolated static validations, 264 predicate cases, eight input-variable checks and ten cross-input DNS collision cases passed. Reviewer repeated the predicate/collision checks. No real tfvars/state or provider-backed plan/apply.                                   |
| Git safeguards                                                           | Mocked child-lint environment isolation and shell syntax passed. `git check-attr` confirms direct/nested synthetic `.age` names use `-text -diff`; file contents were not read.                                                                                            |

### Canonical commands

Run from the candidate root:

```sh
nix fmt
nix --option allow-import-from-derivation false run .#lint -- \
  --diff --base e7f3ef479c42c8cfa89668230782809cb3a3fb3e \
  --system x86_64-linux
nix flake check --no-build --option allow-import-from-derivation false
```

Cargo jobs used `CARGO_BUILD_JOBS=2`, `RUST_TEST_THREADS=2` and one reusable
candidate-local target directory. Native-library tests use the realized Nix
2.34.9 / ABI 3 adapter; their negative preflight cases stop before daemon RPC or
imports. No actual credentials or host deployment are required.

### Focused root checks

Each is `checks.x86_64-linux.<name>` and was realized with
`nix build --no-link --option allow-import-from-derivation false`, bounded to
two build jobs/two cores:

```text
lib-ai-consumer-selection
lib-ai-inference
lib-ai-inference-runtime
lib-ai-lib
lib-ai-module
lib-ai-projection
lib-build-executor-control
lib-abird-host-agent
lib-abird-host-manager
lib-nix-builder-gc-coordination
pvl-nix-builder-gc-defaults
lib-lint-root-flake
lib-lint-no-ifd
lib-lint-manifest-temp-cleanup
lib-flake-rust-bases
lib-flake-rust-native-context
lib-flake-rust-source-scope
lib-flake-rust-source-scope-real
lib-flake-rust-toolchain
pvl-child-flake-parity
```

## Independent combined-diff review

Four separate review lanes covered executor/native code, fleet/frontend/Nix
integration, shared Rust/AI/tooling, and package/Cloudflare changes. All changed
files were inventoried and transfer/parity checked; large runtime subsystems
received focused semantic review of contracts, integration and risky paths, not
a claimed line-by-line security certification of every added line.

### Native consumer admission — repaired and independently closed

Upstream could submit a remote build before discovering that a caller lacked a
compatible native adapter, then retain an import claim without starting import.
The port reuses one immutable-library/ABI/program validator in a bounded,
loader-sanitized subprocess before parent recording, Submit, acquisition binding
and import claims. Consuming caller-only Nix profiles reject incompatible
packages; failed qualification preserves existing uncertain claims.

The independent repair review covered twelve exact files and ran ten focused
cases, including the real ABI3 library and pending-import preservation. Ordinary
Nix routing, disabled profiles and thin CI forwarding remain intact. No
duplicate version parser, pin change or unsafe claim clearing was added.

### Direct-script bootstrap — repaired and independently closed

Upstream bootstrapped the ordinary Nix tool closure before explicit agent
requests delegated to the installed manager. Delegation now precedes bootstrap.
An intermediate ordering repair exposed a sparse-PATH dependency on `awk`, `tr`,
`paste` and help's `cat`; shared selector normalization and help now use Bash
builtins. Regression coverage exercises real entrypoints rather than stubbing
runtime readiness. An unavailable installed manager fails without a legacy
bootstrap fallback.

Independent recheck passed fourteen focused tests, the original twelve cases and
an expanded 182-case sparse-PATH matrix. It also matched frozen-source
normalization in 5,232 byte-level comparisons and verified byte-identical help
without `cat`. Both the original ordering issue and the introduced parser
regression are closed at the final file hashes.

### Shared integration and packages

- Shared Rust/AI/tooling review found no actionable issue; it verified the
  retained optional Cargo lane, lazy-source assertion, no-IFD boundaries,
  neutral AI defaults and unchanged local identity/input/pin seams.
- Package/Cloudflare review found no new in-scope correctness issue. Graphiti's
  absent-only paired fallback prevents mixed credential/URL bindings; source
  strict-required variables are deliberately adapted for public compatibility.
- Existing Terraform limitation: `tf/cloudflare-platform/workers.tf` still
  expects `main_module`/`modules` fields even though validation accepts some
  assets-only objects omitting them. This predates the port and is not changed
  or certified here. Actual declarations were not read or applied.
- Native and frontend repairs, Graphiti compatibility/test improvements,
  effective Cloudflare validation predicates, and narrow lint fixes are explicit
  source-ahead carry-back candidates. No reverse port or publication was
  performed; main integration is recorded separately above.

## Corrected intermediate failures and limits

- The initial final-gate process was interrupted before completion. A resumed
  canonical lint passed, but its subsequent flake evaluation was deliberately
  stopped to refresh the candidate onto concurrent main changes. Neither
  interrupted chain is counted as full final-gate success. All 294 owned file
  hashes were unchanged by the non-forced checkout; Kilo removal and Dotlink
  0.17.0 remain current destination policy. Final gates use the new base above.
- The first lint pass caught a newly written report's formatting; it was fixed
  and the canonical pass then succeeded. Initial background launch without a
  useful log was retried with durable output; it is not counted as validation.
- A native test compilation raced in-progress edits and found a transient
  `controller` namespace error. The worker fixed it; focused tests, actual ABI
  tests and strict Clippy subsequently passed.
- An offline root build began rebuilding unrelated bootstrap dependencies. It
  was intentionally stopped, not counted as success. The ordinary substituted
  twenty-check build subsequently completed successfully.
- Full installed workflow, containment and launch-gate VMs were evaluated and
  registered, **not executed**. Privileged namespace/cgroup/Landlock, reboot,
  GC/cancellation/transport settlement and live rollback qualification remain
  separate. No host opted into the new backend.
- Full `nix flake check` builds, every architecture, the full OpenDesign image,
  source-specific application migrations and real Terraform/cloud operations
  were not performed. Graphiti's explicit pinned runner is a manual
  qualification gate, not silently part of root-flake checks; its existing
  requirements pin direct dependencies, not every transitive dependency.
- Expected warnings include custom flake outputs, synthetic fixtures without
  `system.stateVersion`, existing deadnix warnings and an ignored, transient
  eval-cache SQLite busy warning during parallel checks. Both final jobs exited
  zero; these are not hidden failed gates or newly suppressed errors.
