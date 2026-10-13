---
id: 20261005T090000Z-binary-cache-readiness-started
type: human-approval-and-work-claim
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-fabric-main
state: narrow-binary-cache-readiness
agent_roles:
  - agent:01a10b4b-8b64-7761-baac-12359d27c9be:cache-frontier-analysis
  - agent:01a10b4b-e776-7761-baac-12374234676a:substitute-only-containment-feasibility
tags:
  - area:rust
  - work:g4-qualification
  - constraint:existing-toolchain
---

# Human approved next phase: normal binary-cache readiness

Human: "next phase, let's go", following the narrow cache-readiness blocker. Use
existing Cargo/rustc/Crane/original recipes and current wrappers; no custom
Cargo, compiler/tool bootstrap, source archives, capture/ledger/executor or
blanket build of the1606pending-output graph. Existing semantic host target and
one real supported chain remain selected; no mirror/Abird24/default/publication
or Git mutation. Both retained worktrees/index ownership preserved.

First scope: registered-cache/public policy data and at most12boundary output
coordinates, existing configured official/Pvl/nix-community/numtide cache
narinfo only. At most48requests/64KiB each/3MiB admitted metadata,90s aggregate,
oneCPU/2GiB AS;8s per request and global deadline. No NAR download, compiler,
Cargo/native/product execution or builder fallback. Metadata is availability/
cost data, not authenticated payload or native qualification. No secrets/auth
files/private keys read. No root-flake evaluation or path: refs/IFD.

If a narrow signed substitute closure is actually available, MAIN must declare
its exact paths/closure/cost and independently review copy-only invocation
before payload transfer: existing Nix `copy --from` configured binary caches to
owned private local store, no host daemon, no builders/source fetch/derivation
realization. Require existing trusted signatures; no key-policy change. Bound
300s/oneCPU/2GiB/no swap/1GiB compressed/3GiB decoded aggregate and stop on
unexpected paths/cost/cache miss/containment failure. This is conditional, not
authority to copy an unbounded closure. Payload allocation only after admission.
Fresh offline contained native acceptance/reuse scope (300s
aggregate,onejob/core, 2GiB/no swap/PID256, ordinaryUID/cap0/NNP/private
backend/host lowerRO/no network) only after exact readiness. Do not reopen prior
consumed or withdrawn scopes.

Baseline in `evidence/20261005T090000Z-binary-cache-readiness/before.json`:
PvlHEAD5ae0baf0,926staged/index protected; previous514-file evidence manifest
binding retained. MAIN solely owns network/Nix/runtime calls; two independent
read-only lanes do not execute old archived scripts or broaden human authority.
Stop with concrete cache/cost/support blocker if admission fails; fix only a
newly demonstrated issue, not another replacement framework. Docs/index/work
views and preservation/source evidence closeout gates remain required.
