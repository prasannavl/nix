# Rust foundation: fresh published-range review

Reviewed 2026-10-14; both confirmed findings were then resolved in the main
worktrees. The original review scope and evidence remain below, followed by
corrective validation.

## Frozen scope

- Pvl: `7ac9ff13..418d3aa91b9e804734e14cf36945fe09333c0d47`.
- Abird: `76b1cc65..5ec426d22c76bfa8047ad24eadee4b4ef82a3caf`.

The review included the aggregate changes, commit history, source and context
planning, parent reconstruction, helper compatibility routes, exports, mirrors,
qualification support, publication fixes, Dotlink pin change and Abird's
upstream AW/Codex package integration. Historical private execution bodies were
not read. Retained runtime results keep their original source pins; this review
does not provide a new current-Abird runtime qualification.

## P2 resolved: module omission overrides the declared package-set source

At the reviewed Abird HEAD, `pkgs/srv/abird-agent/module.nix:41` always forwards
`awAgentKernelSource`, whose factory default is null. A direct
`import module.nix {}` therefore explicitly passes null to `default.nix`,
overriding that constructor's `pkgs.awAgentKernelSource` default even when the
host package set declares the exact source. Forcing the default service
package's prePatch/derivation fails evaluation.

A fresh offline, no-IFD evaluation probe with the same package set reproduced:

```json
{
  "directConstructorAcceptsDeclaredPkgsSource": true,
  "moduleDefaultAcceptsDeclaredPkgsSource": false
}
```

The probe supplied an evaluator-visible public fixture as the source control; it
tested omission forwarding, not AW compilation. An independent reviewer
confirmed the interface regression against the before-range module and the
package constructor/overlay contract.

The canonical exported module captures a nonnull source and still works; the
existing standalone test exercises that route, explaining the coverage gap.
Preserve omission when forwarding factory arguments so the package constructor
can use its declared package-set source. Keep explicitly captured source
forwarding and explicit-null refusal. Cover omitted source, explicit source,
explicit null and package override separately.

## P3 resolved: live qualification documentation retains obsolete status and links

In both repositories, `scripts/rust-fabric/qualification/README.md:18` and `:56`
still describe full qualification/integration as open or incomplete in their
current-result section. Lines 59–60 route readers to retired or missing
handoffs. Abird's `.agents/docs/lang-patterns/rust.md:101` also points to the
missing `rust-fabric-abird-port-2026-10.md`.

The indexed main handoff and archived plan give the actual closeout and explain
the subsequent unsupported Cargo.lock.nix policy. Link those current sources
from the live README/language pattern, and label old execution status as
historical. Keep source-pin boundaries explicit; the new lock-policy refusal
must not be presented as a successful current-source runtime qualification.

## Design assessment and validation

No additional confirmed defect was found in declared closure planning,
compilation-context projection, source binding, recursive parent admission,
member composition, mirror generation/publication or toolchain forwarding. The
explicit source boundaries, reconstructed producer identities, shared full
lock/vendor and unsupported-shape refusal are coherent and composable.

One maintenance obligation remains: `pkg-helper.nix:402–422` manually reproduces
Crane's priming commands for chained producers. Keep actual pinned-Crane recipe
and reuse comparisons when updating Crane; this is not a demonstrated current
failure. Qualification runners intentionally retain narrower historical scopes
and external containment requirements.

Fresh validation passed 537 pure assertions per repository across six cache
suites, 13 mirror metadata tests, 29 export assertions and 26 fixture/freshness
parser tests. The module-default probe above reproduced the finding. No new
Cargo builds, VM runs, deployments or dependency/network fetches were performed.

## Corrective validation — 2026-10-14

The Abird module factory now forwards `awAgentKernelSource` only when the caller
supplies that key. Omission preserves the package constructor's declared
package-set default. A captured source remains authoritative, explicit null
still refuses, and factory/service package overrides bypass default source
resolution. The constructor remains the single owner of its dependency default.

The registered `abird-agent-module` check exercises real NixOS module evaluation
and package derivation identities, using public fixtures only as evaluator
source controls. All ten assertions passed on `x86_64-linux` and
`aarch64-linux`: omitted/dependent defaults, captured-source precedence and
standalone export, source-sensitive identity, explicit-null/missing-source
refusal, and factory and service overrides. An offline, no-IFD before/after
control using the published module reproduced refusal before the fix and
successful evaluation afterward. This establishes the argument contract, not a
new AW runtime qualification.

Both qualification READMEs now link to the authoritative main handoff, design
contract and VM note. Historical execution status is explicitly labeled, and
Abird's Rust guidance links to existing documents. The exact qualified source
pins and newer unsupported `Cargo.lock.nix` policy remain distinct.

Targeted Nix formatting and unused-binding checks passed. Statix found no new
diagnostics: the published and repaired module have the same existing W20
repeated-`systemd` style warning; the new test and registration are clean.
Markdown formatting, structural lint, local reference checks and cross-repo
README/note parity passed. Successful temporary regression-control files were
removed. No new Cargo build, VM run, deployment or dependency fetch was needed.
