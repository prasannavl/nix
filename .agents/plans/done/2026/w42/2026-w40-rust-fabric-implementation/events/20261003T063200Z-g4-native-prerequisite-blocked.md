---
id: 20261003T063200Z-g4-native-prerequisite-blocked
at: 2026-10-03T06:32:00Z
actor: agent:rust-fabric-main
type: claim.blocked
subject: milestone:g4-native-qualification-pilot
supersedes: claim:20261003T061200Z-g4-native-approved
tags:
  - area:rust
  - blocker:uncached-external-prerequisite
  - evidence:preflight
---

# Fail-closed preflight: no native build or fetch

Human approved the conditional one-job/core, five-minute, 2 GiB offline x86
archive/parity pilot. Approval explicitly required aborting if containment or
cached prerequisites were unavailable. MAIN stopped at the prerequisite gate; no
native/Cargo build, artifact capture, archive I/O or fetch was started.

## Executed containment probe

Cached immutable Debian image ID `c1f0b46af47a`, rootless Podman,
`--pull=never`, `--network=none`, read-only root/store, all capabilities
dropped, no-new-privileges, 15-second probe lifetime. Explicit existing
user-manager runtime/socket transport was required; no service settings were
changed.

Observed from inside the private container cgroup:

- `memory.max = 2147483648` (2 GiB).
- `memory.swap.max = 0`.
- `cpu.max = 100000 100000` (one aggregate CPU).
- `pids.max = 256`.
- No host Nix-daemon socket present.

Probe container auto-removed. Global daemon still has `MemoryMax=infinity` and
is not an allowed build backend. Sudo is blocked by no-new-privileges; no
attempt was made to bypass it. Private local-store metadata/overlay was
discussed by the read-only advisor but **not executed or validated**. A cgroup
probe is not actual Nix-builder/backend acceptance.

## Executed dependency preflight

Fresh baseline fixture and 52-file helper/harness-only snapshot, with tests
excluded and symlinks/keys rejected before copying. No whole-repository mount,
archive, secret content read or worktree source rewrite. Offline specific-module
no-IFD evaluation produced the two exact acceptance targets. Read-only
derivation metadata and cache validity checks pruned cached outputs, unlike the
earlier incomplete direct-input readiness observation.

First uncached external source:

`/nix/store/s623a3sg7zf5f800h9iqy90dfvgqm8sd-crate-toml-1.1.3+spec-1.1.0.tar.gz`

Actual dependency chain:

```text
rust-g4-archive-chain-acceptance
  -> rust-closure-base-deps-1
  -> cargo-workspace-source
  -> Cargo.toml
  -> crane-utils-0.0.1
  -> cargo-vendor-dir
  -> toml-1.1.3+spec-1.1.0
  -> crate-toml-1.1.3+spec-1.1.0.tar.gz
```

The writer's native tooling is an external prerequisite, not a fixture build
allowed by the pilot. This is the first blocker, **not an exhaustive
missing-cache inventory**. No substituter/network operation or tool compilation
was attempted. Do not substitute a different TOML writer/Crane/compiler to avoid
the contract.

Installed Nix JSON may omit fixed-output `outputs.*.path`. Resolve it with
read-only `nix-store --query --outputs DRV`, then query cache validity; omission
alone neither proves a missing output nor allows assuming it cached. The
resolved source above was explicitly confirmed invalid/uncached.

## State and next gate

MAIN lane blocked; advisor complete; no native lane running. Producer remains
`qualified = false`, `not_proven`; actual inheritance/freshness/parity
unobserved. No publication/adoption/config/default changes. Existing 190 staged
paths preserved, HEAD/Pvl master `5ae0baf0`, Abird master `1f4057ee`.

Failed-preflight diagnostics (4.5 MiB) retained while useful at
`tmp/g4-native-20261003T061200Z/`, including fixture/snapshot, exact
target/derivation metadata, cgroup JSON and `preflight-result.json`. Ask human
whether to retain or remove. Most-specific indexed note, canonical plan and work
view updated.

Next: separately populate/authorize external cached Crane writer prerequisites,
then repeat the complete pruned cache gate and verify the isolated local-store
backend before spending the already bounded native budget. No implicit fetch,
expanded tooling builds, global daemon fallback or resource-limit relaxation.
