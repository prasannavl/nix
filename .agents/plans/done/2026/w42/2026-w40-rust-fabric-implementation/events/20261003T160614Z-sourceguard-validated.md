---
id: 20261003T160614Z-sourceguard-validated
at: 2026-10-03T16:06:14Z
actor: agent:rust-fabric-sourceguard
type: validation.completed
subject: guard:synthetic-descriptor-extensions
tags:
  - area:rust
  - role:assigned-sourceguard
  - evidence:synthetic-only
  - gate:exact-producer-not-proven
---

# Synthetic descriptor guard validated

Claim: `20261003T160303Z-sourceguard-claimed.md`.

Changed only `scripts/rust-unit-spike/spike.py::descriptor`, seven relevant new
cases in `scripts/rust-unit-spike/tests/test_spike.py`, the harness README
synthetic section, and these append-only events. No source-key/native/G4
implementation changes, production ledger/emitter/executor, public adopter,
Cargo execution, fetches, containers, staging or commits. MAIN's shared docs,
canonical plan and materialized work view were not edited.

## Durable paragraph for MAIN

`descriptor()` now rejects non-object units with `ValueError` before field
access. Its complete top-level allowlist is `context`, `package`, `target`,
`role`, `triple`, `features`, `profile`, `rustflags`, `edges`, `build_script`,
plus opaque non-identity labels `id`, `demand`, `plan_stamp`, `capsule_stamp`,
`lock_stamp`. Existing test consumers use `demand` and the three stamp names;
`id` preserves the explicitly assigned unit-label contract. No inferred alias
such as `unit_id`, `plan_freshness` or `lock_sha256` is accepted. Label values
remain intentionally untyped and excluded from identity, not evidence or
compilation inputs. Every exact-field wrapper must have exactly `status` and
`value`, with explicit `status: exact`; missing keys and extra attributes
(including `attrs` and `provenance`) fail closed. This prevents unknown flags,
effects, native context and proc-macro edge extensions from being silently
dropped before hashing. Profile dictionaries retain their arbitrary synthetic
semantics and are hashed as before. Existing normal/build/dev edge validation
still rejects explicit proc-macro edge kinds and additional edge attributes; a
synthetic host proc-macro target remains accepted without edge inference. This
is only a synthetic schema guard, never trusted capture: results stay
`scope: synthetic_schema_only`, `producer_qualified: false`, and real exact
producer availability stays `not_proven`. G4's actual role fixture is not routed
through this descriptor and remains a separate evidence path.

## Validation

- Before changes:
  `python3 -B -m unittest discover -s
  scripts/rust-unit-spike/tests` — **56
  passed**.
- After changes: the same suite with `-v` — **63 passed** (56 existing + 7 new).
  New controls cover non-object units; unknown top-level flags/effects/native
  context/proc-macro edges; unsupported wrapper attributes on all ten fields;
  missing wrapper status/value; all five opaque labels individually and
  together; unsupported proc-macro edges with a still-accepted synthetic host
  target; and arbitrary hashed profile values.
- Existing normalization, ordered flags, divergent identity, deep snapshots,
  build-time script references, plan/lock neutrality, mocked report
  `decision: not_proven`, process cleanup and seven static role-fixture checks
  all pass unchanged.
- `python3 -B -m unittest discover -s scripts/rust-g4-qualification -p
  test_fixture.py -v`
  — **28 passed**, pure declaration/source/generator filesystem checks only,
  including the actual G4 proc-macro/build/dev topology. No new native
  acceptance claim or requalification.
- Targeted Deno Markdown formatting/check and owned-file diff whitespace checks
  pass. Tests create and clean only their normal checkout-root `tmp/` scratch;
  no unrelated temporary state was removed.

These checks are owner validation, not an independent review claim. Exact
capture, compilation-unit fidelity and production executor qualification remain
open; MAIN owns indexed durable-doc integration and G4 orchestrator owns native
execution. All code changes remain unstaged/uncommitted.
