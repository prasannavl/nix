---
type: decision
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-fabric-main
status: source-work-and-finite-metadata-preparation
tags:
  - area:rust
  - policy:public-upstream-source
---

# Public upstream fixture provenance, not needless cache exclusions

Human challenged why an upstream package fixture should lose cache reuse. MAIN
acknowledged that Sensitive/nar is inspector policy, not Cargo invalidity;
filename alone cannot classify a live secret. Human approves establishing exact
locked upstream provenance and narrowly allowing opaque cache verification while
actual secrets and unknown paths remain blocked: “excellent, let's do it and
proceed.” This supersedes the proposed additional-exclusion/rematerialization
route in event061533Z; do not implement that proposal merely because of .pem.

The known current path is DER0.7.10 tests/examples/spki.pem, rootordinal8 of381.
Current diagnosis stopped pre-stat/body; native historical rejected paths are
still unknown. Name suggests SPKI but does not prove body semantics. Public
upstream test data must be distinguished by exact locked
source/recipe/registered NAR/owner/path role, not an extension-wide exemption or
public-package-prefix heuristic. Live data/secrets keys, actual
mutex/database/auth/private trees, unknown/unqualified paths and
alias/link/hardlink/writable/foreign-owner cases retain prebody denials. No PEM
parsing, text disclosure or fixture stripping.

Owned source streams, MAIN alone performs actual permitted operations:

- agent01a1151f-8a05-77eb-a00f-6896b686bc7a prepares precise provenance and
  shared helper/retained-copy/guest-rehash policy under
  rust-public-upstream-fixture-20261007T064657Z; frozen/executed versions stay
  immutable. Begin exact known DER path, no guessed extra exceptions.
- agent01a11520-4033-77eb-a00f-689829b5d4c4 prepares bounded MAIN filename-only
  inventory under rust-public-upstream-name-inventory-20261007T064657Z to avoid
  blind native attempts and identify remaining guard collisions. No payload body
  reads; guarded names skipped before stat/descent. Proposed one30-second
  metadata scope, CPU1/AS512MiB/CPU20,100000 total name occurrences across both
  passes/8MiB names/4096 records/2MiB output, fails closed on exhaustion.

Both streams are source/public saved metadata and bounded pure/mock controls
only, no protected cache/DB/archive/key/fixture/mutex payloads, Nix/Podman/Cargo
or network by subagents. MAIN execution requires independent source review,
exact freeze/source bindings and fresh finite physical/FD custody. A locked
catalog is provenance, not current cache content PASS or authority to inspect
other protected bodies. Any missing necessary provenance or failed bounded
inventory must trigger consultation rather than renewed/widened execution.

Original Cargo1.95/Crane/constructors/wrappers/toolchains/features/checks/full
lock/flat-FOD/unpack/vendor recipes remain authoritative. Existing381/3824/365
roles and original four recovery recipes are unchanged in this correction. No
new native300 is granted here: prior mission nativeA300 and separately approved
fresh300 are CLOSED; metadata360 CLOSED. Other goal-specific ceilings remain
unarmed, not recovery retries. Fresh native authority will be requested only
after complete narrow policy/integration review and fresh admission. Manager/cs5
warm/locality/mirror/Abird/platform remain unqualified; no Git
integration/default adoption or protected cleanup authority.
