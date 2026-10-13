---
id: 20261003T054000Z-g4-qualification-prepared
at: 2026-10-03T05:40:00Z
actor: agent:rust-fabric-main
type: validation.completed
subject: milestone:g4-execution-qualification-preparation
tags:
  - area:rust
  - authority:code-only
  - evidence:construction
  - state:uncommitted
---

# Explicit G4 qualification preparation complete; native acceptance deferred

Human requested "next phase". Claims/roles/authority:
`20261003T045200Z-g4-qualification-claimed.md`. This stage prepared isolated
fixtures/targets without widening compilation/capture/fetch/root/host/adoption/
integration/publication authority or changing production helpers/defaults.

## Implementation and decisions

Six files under `scripts/rust-g4-qualification/`:

- `fixture.py`, `test_fixture.py`: real seven-member std-only resolver-2 role
  workspace, generated local lock v4, baseline/Rust/manifest/raw-lock variants,
  exclusive safe materialization with private staging and atomic no-replace.
- `default.nix`: actual helper construction, 13 explicit build targets, two
  explicit acceptance targets, source/lock/vendor/stdenv/parent/output
  observations.
- `eval.nix`: actual chaining/context/mode/admission/rollback/locality
  assertions.
- `accept.nix`: separately realized bounded target-archive link/name inspection
  and exact baseline/member/legacy stdout parity. Private constructed handles
  supplied by entrypoint; no recursive re-import, producer override, sentinel or
  fake logs.
- Script README added by MAIN: exact code-only instructions, target interface,
  evidence boundaries and approval/daemon-containment gate.

Six files total: fixture/test, three Nix modules and README. No root check
registration or production inventory/ledger/executor.

Prior capture fixture remains unchanged; its dev/default-member assumptions are
unsuitable for subset priming. New source uses normal/build/macro/dev features,
checked-in build input, consumed environment and actual proc/dev behavior.
Static Rust review only; no compilation/feature-resolution acceptance yet.

A raw lock comment changes full-lock/base paths globally while parsed vendor
stays identical. This is intentional evidence, not a claim that comments change
resolution or every lock-byte edit changes every vendor output. Source edit
preserves bases and vendor; containing member layers change and peer remains
stable. Manifest edit is closure-local.

## Independent findings and repairs

Reviewer `01a10027-6e36-74c4-80f2-1d078735918d`:

1. P1 expected stdout path was repository-local after `toString`, missing
   sandbox input context. Actual file now imported into store; context
   regression passes.
2. P2 partial writes survived materializer failures. Same-parent private staging
   and Linux `renameat2(RENAME_NOREPLACE)` clean failures and protect concurrent
   targets; failure/retry/race tests pass. No unsafe fallback or unrelated
   cleanup.
3. P2 archive names admitted secret/key paths. Pure/runtime component filters
   reject `data/secrets`, `.git`, `.key`, controls/backslashes and existing
   traversal/bounds.
4. P2 README `--file --arg --json` invocation did not apply the function.
   Corrected explicit `--expr` import application; MAIN reproduced 26 assertions
   successfully.

Reviewer verified the first three repairs: 28 tests, store input context and
matching/ wrong stdin, 19 synthetic name cases agreeing between pure and actual
awk filters. No native binaries/Cargo archives were exercised. Final
documentation finding is fixed and its exact invocation independently rerun by
MAIN.

## Executed evidence

- **28** fixture/atomicity/variant/safety Python tests pass.
- **26** actual assertions per cached bare/overlay x86/ARM Linux context pass.
- All **13 build / two acceptance** derivation paths evaluate in each context.
- Existing **185 support / 56 spike** tests pass; root lock/13 child refs
  unchanged.
- Synthetic generated-shell syntax/ShellCheck and **19** archive-name controls
  pass.
- Read-only base-app metadata preflight: **1,479** derivation records inspected,
  no realization; **13/16 direct input outputs** cached including
  compiler/tools/hooks. Parent base/workspace source/lock are unrealized. This
  is not full pruned readiness.
- Alejandra, Deno formatting and whitespace checks pass; staged diff empty.

Production helper code unchanged by this slice; masters remain Pvl `5ae0baf0`,
Abird `1f4057ee`. No Cargo/native/daemon build, capture, archive I/O,
provider/network fetch, full-root/host execution, real secret read, commit or
publication.

Most-specific indexed qualification note, canonical plan and materialized work
view updated. Successful owned fixture/evaluator/test snapshots cleaned;
unrelated `tmp/helper-consolidation` remains. Plan stays active/queued, not
archived.

## Remaining gate

Producer remains `qualified = false`, `not_proven`. Archive
structure/constructor edges and package stdout are not actual extraction, Cargo
freshness, external reuse, exact units/features/roles/effects,
native/platform/cost or adoption proof. Future runs must retain real inheritance
logs; missing observations cannot become synthetic success. No opaque
observation metadata admits artifacts.

Next is a separately approved small native target set with dependency preflight,
explicit jobs/cores/wall/memory/retention limits and external containment
covering Nix daemon builders. Client `ulimit`/timeout is insufficient. Do not
automatically build, fetch, broaden platforms/variants or integrate/publish from
this preparation.
