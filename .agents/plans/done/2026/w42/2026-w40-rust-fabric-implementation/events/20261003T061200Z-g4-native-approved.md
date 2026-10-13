---
id: 20261003T061200Z-g4-native-approved
at: 2026-10-03T06:12:00Z
actor: agent:rust-fabric-main
type: claim.started
subject: milestone:g4-native-qualification-pilot
tags:
  - area:rust
  - authority:bounded-native
  - scope:x86_64-linux
---

# Human approves bounded native archive/parity pilot, conditional on containment

Proposal: one offline x86_64 native archive/parity run, one job/core, five
minutes, 2 GiB, verified isolated containment of all builders; abort if
containment/cached prerequisites unavailable. No fetches, commits, adoption or
publication. Human response: "go ahead".

MAIN is coordinator/execution owner. Metadata-only containment advisor:
`01a10064-1644-74c4-80f2-1d1c30e9e577`; no competing native execution lane.
Targets: existing `acceptanceTargets.archiveChain` and `.semantic`, with only
their fixture/support dependency closure, standard build logs and observation
outputs. Do not include unrelated tests/variants/platforms or producer adapters.

Global nix-daemon remains unbounded and is not an execution backend.
Noninteractive sudo is blocked by no-new-privileges; user manager transport is
unset, although its runtime sockets exist. Cached Podman images exist.
Investigate an isolated cached container/local-store backend with no host daemon
socket, explicit cgroup memory/ CPU/wall limits and no pull/network; verify
before any Cargo/native build. No shared daemon limit change, privilege
workaround or missing-cache filling.

Temporary owned state under repo `tmp/`. Retain failed diagnostics while useful;
successful evidence must be consolidated into indexed notes/events before
cleanup. Existing 190 staged paths are preserved; phase performs no
index/history operations. Runtime acceptance cannot qualify exact producer
units/features/effects/external reuse; `qualified = false`, `not_proven` remains
until separate fidelity evidence.
