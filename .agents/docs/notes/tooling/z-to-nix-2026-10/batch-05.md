# Reverse batch 05 — source rows 101–125

- Global frozen rows 184–208: 25 commits, no merges, 114 first-parent path
  events / 41 unique paths. Complete ledger: `batch-05-paths.tsv`.
- Review `worktrees/z-to-nix-05` / `review/z-to-nix-05`, base checkpoint 04
  `b8af31d6a4fa09362e02f0e129f4aea4ce04712a`. Own documentation-only delta stays
  staged; separate signed checkpoint supplies batch 06.
- Cumulative review: 125/227. Main remains approved batch 03; no further main
  integration, review-worktree removal, push or deployment.

## Commit dispositions

| Reverse / global | Source     | Disposition                       | Rationale                                                                                                                                                                         |
| ---------------- | ---------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 101 / 184        | `f66a529d` | retained host policy              | Stopped Gondor guests and preserved data are local 28GiB capacity choices; no guest mutation.                                                                                     |
| 102 / 185        | `ddd4c7e5` | retained host policy              | Named-guest OOM priorities are physical-host policy, not shared Incus defaults.                                                                                                   |
| 103 / 186        | `690fe810` | retained host release hold        | Historical Forgejo 17 regression hold belongs to absent Abird Corp deployment. No destination host/user/config Forgejo consumer; no image or upgrade change.                      |
| 104 / 187        | `a5831813` | retained private protocol         | Usage-limit classification spans private Codex/provider/store/workflow/protocol contracts; no isolated enum or state change imported.                                             |
| 105 / 188        | `adb4a645` | retained private restore unit     | Restore cursor/fencing and durable receipt validation belong to the private agent database; no backup execution or state migration.                                               |
| 106 / 189        | `83952cc1` | retained private contract unit    | Exact schema/policy checks, source pin and bounded Structured Outputs are coupled to private agent policy; preserve existing destination Codex wrapper.                           |
| 107 / 190        | `02e66c1d` | retained owned migration evidence | Abird ledger relocation is repository-owned coverage. Historical filename is retired; keep Pvl topology sibling and generic tests, do not import an unverified Rust-parity claim. |
| 108 / 191        | `29949116` | retained private admission fix    | Remove retired CLAUDE root from private packaged-workspace admission, not from a destination product.                                                                             |
| 109 / 192        | `e0804400` | retained private rollout          | Private correction/backup deployment receipts and queue updates stay local; no destination acceptance claim.                                                                      |
| 110 / 193        | `5e384202` | retained private application unit | Admission errors, restored-workflow capacity and local timestamps span private controller/web/browser tests.                                                                      |
| 111 / 194        | `ebd17a5b` | retained private rollout          | Workflow recovery deployment records do not establish destination acceptance.                                                                                                     |
| 112 / 195        | `c39952b3` | retained private transport unit   | Half-close propagation, bounded broker cleanup and tests belong to private Codex transport, not shared host-control transport.                                                    |
| 113 / 196        | `d4ed5916` | retained private session unit     | Validated-cursor reconnect, bounded presence retry and grant UI are private app authentication policy; no profile/session activation.                                             |
| 114 / 197        | `8018087e` | retained private rollout          | Private app/web and sign-in delivery records remain source-owned.                                                                                                                 |
| 115 / 198        | `d2f0e606` | retained private transport unit   | Closed-peer versus failed transport preserves validated private Codex results with byte/authority bounds; no generic host-tool change.                                            |
| 116 / 199        | `4f9af1b4` | retained private rollout          | Socket-cleanup deployment history remains local.                                                                                                                                  |
| 117 / 200        | `88d85fce` | retained private runtime unit     | Contained process mask, private mount target, public UUID exception and local-fake-provider fixture remain coupled; do not run containers.                                        |
| 118 / 201        | `f47e7aa6` | retained private rollout          | Runtime permission rollout evidence is not destination acceptance.                                                                                                                |
| 119 / 202        | `f0b4e06b` | retained private accounting unit  | Whole-turn accounting, current-output limits and transport-specific retained digests span private provider/store/workflow; no partial import.                                     |
| 120 / 203        | `ca8ec298` | retained private rollout          | Response-settlement deployment receipts remain source-owned.                                                                                                                      |
| 121 / 204        | `627a6e25` | retained private UI unit          | Workflow question CSS and browser checks belong to absent Abird Web, not shared terminal output.                                                                                  |
| 122 / 205        | `cad4e903` | retained private failure unit     | Durable provider throttling differs from quota exhaustion; protocol/provider/store/workflow changes remain one private unit.                                                      |
| 123 / 206        | `9543c7cf` | retained private rollout          | Throttling rollout evidence and source coordination remain local.                                                                                                                 |
| 124 / 207        | `c030c193` | retained coherent private unit    | Deny-tools patch, bounded controller instructions, runtime policy and fixtures depend on private Abird authority; do not change destination Codex tool policy.                    |
| 125 / 208        | `a11536ce` | retained private rollout          | Instruction-policy deployment history remains source-owned; no live acceptance claim.                                                                                             |

## Ownership boundaries

- No implementation/test/config/input changes. Private Abird agent, protocol,
  desktop/web and Codex App Server roots are absent in nix. Current App Server
  constructor reads private `codex-protocol-policy.json` and applies its coupled
  instruction/tool/diagnostic patches; do not extract an obsolete partial unit
  or impose private no-tools policy on the destination Codex wrapper.
- Restore/fencing, usage accounting, throttling, session reconnect and runtime
  permission changes remain coherent private units. Reviewing their ownership
  does not certify their behavior; no private tests, containers, backups,
  credentials or live workflows were executed.
- Gondor guest stop/OOM settings remain physical policy. Forgejo 16.0.6 hold
  documents a historical source-host advisory, not a current security claim.
  Destination host/user/config trees contain no Forgejo consumer; preserve the
  shared helper without inventing a deployment or upgrade.
- Row 107 only relocates Abird migration evidence and its identity check. The
  old ledger filename is retired; source later renames it in row 222. Current
  source has 332 declared generic test methods plus its parity-check sibling;
  destination has 307 generic methods plus its Pvl topology sibling. These
  inventories and Rust parity claims are not interchangeable. Retain all
  destination tests; authorize no legacy removal. Subsequent generic tool
  changes still receive their own source review.
- Source-only rollout/acceptance notes and plan queue are not copied. Keep MIT,
  all inputs/Dotlink, Rust policy, package membership, Tailscale hold and
  unresolved Incus downgrade deployment boundary.

## Validation scope

- Canonical offline format/lint and complete first-parent ledger/path/type/mode
  guards precede checkpoint creation. Verify every non-`.agents` top-level Git
  tree entry is unchanged, including code, tests, configuration and locks.
- Fresh all-system no-build evaluation runs with IFD disabled; force all 175
  registered check derivations (88 x86 Linux / 87 ARM Linux / 0 Darwin).
- No changed executable unit needs a new behavioral negative control or build.
  Batch-04 behavioral evidence remains predecessor evidence, not a fresh
  batch-05 runtime execution or rendered-unit/derivation identity claim.
- Preserve batch-04 staged tree and all unrelated refs/worktrees. Global
  byte/type/mode/presence compatibility remains a separate later phase.

## Path dispositions

- retained-coherent-private-product: 49.
- retained-destination-coordination: 1.
- retained-host-policy: 3.
- retained-identity-test: 1.
- retained-source-evidence: 59.
- retired-owned-ledger-layout: 1.
