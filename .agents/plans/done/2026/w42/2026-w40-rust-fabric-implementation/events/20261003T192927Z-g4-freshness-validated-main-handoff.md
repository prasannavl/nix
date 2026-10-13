---
id: 20261003T192927Z-g4-freshness-validated-main-handoff
at: 2026-10-03T19:29:27Z
actor: agent:g4-final-owner-01a10312
type: validation.recorded
subject: native:g4-freshness
routing_tags:
  - area:rust
  - validation:actual-cargo-freshness
  - ownership:main-product
  - budget:same-aggregate
---

# Actual freshness PASS and exclusive MAIN handoff

One independent read-only reviewer cleared hermetic tests before execution,
reviewed each repair against exact source hashes, and passed the actual Cargo
JSON/stdout evidence. Ten final mocked tests pass with production-four and
adapter-three hashes unchanged before/after each test and invocation. Production
fixture/module/evaluator remain restored trusted bytes; the harness now safely
admits actual Crane regular-file hardlinks only to earlier validated regular
entries, rejecting duplicate canonical destinations, traversal, symlinks and
devices. Warm/locked/role checks were not weakened or rolled back.

Four contained attempts preserve the SAME grant, including failures:

| Attempt  | Exit | Charged wall seconds | Outcome                                                                         |
| -------- | ---- | -------------------: | ------------------------------------------------------------------------------- |
| f4195d0d | 1    |          2.709702809 | Illegal nix-store caret selector, before compilation                            |
| 70ac59e2 | 1    |          2.715805182 | Correct offline nix build; privateTools join built; original-source read denied |
| 61c56bac | 1    |          1.351696615 | Source exposure repaired; safe archive parser rejected actual hardlink          |
| 03a7189e | 0    |         10.678216455 | All four variants and sixteen phases passed                                     |

Selector fixed to cached `nix build --offline --no-link DRV^out`, with local
private DB and exact pruned cached prerequisites. Original fixtures0700/0600
stay unchanged; an approved baseline-only byte/mtime-verified immutable snapshot
is mounted read-only at the canonical source path. Original76 hashes match
before and after. All current seven source hashes and old adapters/older closed
ledgers also match. Only the known privateTools support join built; no FOD
download, host build, root daemon, source ownership change or product execution
by this owner.

## Actual observations, not guessed unit authority

Forty-eight actual Cargo commands are release/offline/locked/jobs1, with equal
full-lock pre/post hashes. App/test binaries really ran: all32 outputs pass.
Host build/macro and target normal/dev feature roles are retained in raw JSON.

- Every warmBaseline and warmNoOp artifact is fresh.
- Rust edit dirties app/test while peer remains fresh.
- Unused-feature manifest edit also dirties app/test while peer remains fresh:
  **not freshness-neutral**.
- Raw lock-comment delta leaves all emitted artifacts fresh.
- Restored priming is allowed to compile; no fresh restored-prime claim.

PID1 deadline, UID/GID1000, zero worker capabilities, NNP,2GiB/no swap,CPU1,
PID256,read-only cgroup, no network/daemon, child reaping and nonce/source-bound
terminal records are retained. All four completions and exact container absence
were validated under `controller.lock` at handoff.

## Exclusive ownership transferred immediately

At19:29:27Z, following MAIN's explicit close/handoff instruction, the freshness
runner ledger became **CLOSED**, with `handoff: main-product`,
`allocationStatus: TRANSFERRED_OPEN`, and `resumeFreshnessAuthorized: false`.
This closes the former owner's runner, NOT the unused aggregate allocation. No
row, charge, prior reservation or300s aggregate limit was reset or removed.

- Spent: **17.455421061022207s**.
- Remaining transferred: **282.5445789389778s**.
- MAIN product maximum: **min(180s, remaining) =180s**, binding parent
  spent/hash.
- Parent ledger:
  `tmp/g4-native-invalidation-20261003T133000Z/aggregate-budget-20261003T154900Z.json`.
- Closed-parent SHA256:
  `269ecb25120174f56c1b0c7736c4aee9e52907a7239e6c7bfd1354147c49641c`.
- Authoritative transfer:
  `tmp/g4-final-20261003T184149Z/EXCLUSIVE-NATIVE-HANDOFF.json`.

MAIN exclusively owns subsequent cache/native writes. This owner performs no
further builds, launches, cache controls or budget changes. Private cache and
privateTools output remain retained. Earlier frozen300 and closed82.211763s
ledgers are unchanged. Actual output:
`tmp/g4-native-invalidation-20261003T133000Z/replay-20261003T154900Z/final4-20261003T192500Z`.
Raw source gates/tests/runtime review and observations:
`tmp/g4-final-20261003T184149Z/`. Durable selected evidence is promoted to
`evidence/20261003T192927Z-g4-freshness/` under this work capsule, without
copying runtime targets, whole archives or dirty trees.

Exact producer, unit DAG, external reuse, cost savings, representative product
qualification and default adoption remain **not_proven**. MAIN's product work,
canonical documentation/index and shared work README are not edited here.
