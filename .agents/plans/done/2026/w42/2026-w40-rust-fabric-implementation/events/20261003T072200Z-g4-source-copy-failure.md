---
id: 20261003T072200Z-g4-source-copy-failure
at: 2026-10-03T07:22:00Z
actor: agent:rust-fabric-main
type: claim.blocked
subject: milestone:g4-native-qualification-pilot
tags:
  - area:rust
  - finding:source-copy-permissions
  - evidence:bounded-native-attempt
---

# Writer built; first fixture attempt exposes read-only manifest replacement

Separately approved writer step succeeded in **39 seconds**, inside private
local store/capped rootless container. Six tool/support derivations built; only
two locked SHA-256 crate sources fetched from declared static.crates.io URLs.
Actual tool Cargo build/check logs show one job, offline compilation, release,
native x86. No remote builders/substituters, host daemon/store output
publication or default changes.

Full private-store pruned prerequisite check then passed: 43 unrealized fixture/
support derivations, no missing fixed-output sources/external native tooling.
Network-none fixture attempt failed in **2 seconds**, before fixture Rust
compilation or archive/semantic acceptance. Memory/no-swap/CPU/PID constraints
were asserted inside both containers. Probe/build containers auto-removed.

## Concrete root cause

Actual failed source derivation:
`/nix/store/4h1ncxzx9ixhwxqx73f7jrnj2jqcnwsq-cargo-workspace-source.drv`.

Crane dummy construction copies cleaned source and chmods it writable, then
writes new cleaned manifests from read-only store files. A newly created root
Cargo.toml is mode 0444. `constructClosureBase` appends
`cp ${projectedRoot} $out/Cargo.toml` to replace workspace membership, which
fails without write permission. This is normal unprivileged-builder behavior,
not a reason to add DAC_OVERRIDE or weaken containment. Mirror workspaceSrc
already makes its copied manifest writable before replacement.

Code-only repair claimed by `01a10096-02cb-74c4-80f2-1d2ec202bf1a`: shared
writable root-manifest replacement script for chained/unchained bases, focused
generation/ unprivileged-shell regression, Alejandra/pure construction checks.
MAIN owns fresh construction/default identity comparison and documentation. No
native retry lane running. Opt-in producer identities necessarily change to
repair the previously unbuildable source command; do not pretend old source
derivation identities remain valid. Default/null union/legacy paths must remain
unchanged.

## Preserved state

All 19 fixture source/manifest/full-lock/expected-output files unchanged by
hashes. Private source/tool cache and failed logs retained at
`tmp/g4-native-20261003T061200Z/`; host tool output remains uncached,
demonstrating no host publication. Private overlay work directory has
namespace-owned metadata; do not force-delete/chown unrelated state. Existing
190 staged paths preserved; HEAD/master identities unchanged. No commits, host
config/deploy/adoption, provider switches, exact unit producer or Cargo
instrumentation capture.

`qualified = false`, `not_proven`. Source command failure provides no G4 archive
inheritance, Cargo freshness, fixture role/semantic/runtime/cost acceptance.
After code-only repair/validation, seek another explicitly bounded offline
retry; do not silently rerun, relax limits or change compiler/writer/source
recipe.
