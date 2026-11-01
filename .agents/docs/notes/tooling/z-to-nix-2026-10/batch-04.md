# Reverse batch 04 — source rows 76–100

- Global frozen rows 159–183: 25 commits, no merges, 5113 first-parent path
  events / 5032 unique paths. Complete ledger: `batch-04-paths.tsv`.
- Review `worktrees/z-to-nix-04` / `review/z-to-nix-04`, base checkpoint 03
  `d4c96718e0e925776073e12dcd05c1be09ea6df7`.
- Own delta remains staged; separate signed checkpoint 04 supplies batch 05.
  Main has approved batches 01–03. Reviewed cumulatively: 100 / 227.

## Commit dispositions

| Reverse / global | Source     | Disposition                           | Rationale                                                                                                                                                                                                                        |
| ---------------- | ---------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 76 / 159         | `55231272` | retained private rollout              | Dispatch deployment evidence belongs to the private agent, not destination acceptance.                                                                                                                                           |
| 77 / 160         | `51edbaf0` | retained private protocol             | Optional signed notification timestamps and strict unknown-field rejection belong to the private pinned Codex adapter.                                                                                                           |
| 78 / 161         | `3f2339b6` | retained private rollout              | Notification rollout/custody records stay with their source product.                                                                                                                                                             |
| 79 / 162         | `a3b42bec` | retained private protocol             | Transport-only union/schema lowering and result-envelope unwrapping remain coupled to private controller validation.                                                                                                             |
| 80 / 163         | `a1eeb4d4` | retained private rollout              | Structured-output deployment evidence is not a generic implementation unit.                                                                                                                                                      |
| 81 / 164         | `e5f10cff` | retained local formatting             | Private schema-rollout prose remains source-owned.                                                                                                                                                                               |
| 82 / 165         | `ccdee63c` | retained private protocol             | Moderation-metadata notification suppression is the private pinned adapter contract.                                                                                                                                             |
| 83 / 166         | `5cc38df8` | retained private rollout              | No source rollout operation or acceptance claim is imported.                                                                                                                                                                     |
| 84 / 167         | `863d96de` | retained coherent private unit        | Effective context windows, durable usage, notification allowlists and disabled runtime capabilities stay with the private agent/config/store.                                                                                    |
| 85 / 168         | `e75cce6d` | retained private rollout              | Keep source deployment receipt and outstanding authenticated desktop boundary local.                                                                                                                                             |
| 86 / 169         | `41aec5c3` | retained local formatting             | Do not rewrite private Codex rollout history.                                                                                                                                                                                    |
| 87 / 170         | `aa5053e6` | already retired / retained caller     | CLAUDE shim is absent in both current trees; private agent host fileset remains local.                                                                                                                                           |
| 88 / 171         | `d192448f` | already adopted / retained suffix     | Canonical ignore header matches byte-for-byte; preserve repository-specific rules.                                                                                                                                               |
| 89 / 172         | `6fd27dd6` | already adopted / retained history    | Shared AGENTS sections and plan README match; docs index and TODO-SPEC stay retired. Queue/custody remain repository-owned.                                                                                                      |
| 90 / 173         | `12b1a842` | retained owned migration              | All 4978 first-parent events are planning-only. Do not import private archives or delete six extant destination Rust custody paths.                                                                                              |
| 91 / 174         | `e1dd54f1` | already adopted / retained history    | Shared current plan spec and AGENTS conventions exist; formatting private HISTORY files is not shared authority.                                                                                                                 |
| 92 / 175         | `89409572` | retained owned history                | Lint-safe headings repair source migration records; no destination history rewrite.                                                                                                                                              |
| 93 / 176         | `cac030ce` | retained private plan                 | Phase-4c tracking and pending deployment state remain private product coordination.                                                                                                                                              |
| 94 / 177         | `90af4903` | already adopted                       | Current common monorepo guidance lists the docs tree instead of maintaining an index.                                                                                                                                            |
| 95 / 178         | `189d1f3a` | already adopted                       | Current common guidance permits 2–3 levels of docs-tree discovery.                                                                                                                                                               |
| 96 / 179         | `901c42f7` | already adopted                       | Current shared terse-writing rule matches.                                                                                                                                                                                       |
| 97 / 180         | `5feb5219` | already adopted                       | Current owned-path, owner/coordinator and clean-push rules match.                                                                                                                                                                |
| 98 / 181         | `2c2c2299` | already adopted                       | Current shared terse-output rule matches.                                                                                                                                                                                        |
| 99 / 182         | `f7a76eed` | mixed: preserve pins / repair binding | Shared pins, Tailscale constructors and Solaar selection already exist or are newer. Preserve all input/host policy. Current-path review exposes missing shared Stalwart CLI binding; carry it forward with regression coverage. |
| 100 / 183        | `34185bdc` | retained host capacity policy         | 28GiB Gondor app/proxy removals are physical/product choices, not portable defaults.                                                                                                                                             |

## Shared caller repair

- Only production change: select the existing `lib/ext/stalwart-cli` constructor
  as `pkgs.stalwart-cli`. The shared service constructor already binds that
  attribute into `STALWART_CLI_BIN`; baseline selected nixpkgs **0.15.5**
  despite the repository-owned **1.0.14** pin. Preserve that pin and all four
  archive records; do not change host images, credentials, service behavior or
  inputs.
- This binding predates row 99: provenance
  `45e9ef52a0bdcea8c17f176b8fc84413e710b9ca`, retained in current z. Row 99
  itself adds Solaar, which already exists in nix. Record the Stalwart repair as
  a current-path carry-forward, not a new frozen-queue entry.
- New package-owned check asserts selected derivation identity and the actual
  service constructor's CLI environment binding. A capture fixture does not
  execute the service. Aggregate and passthru registration retain existing
  tests.
- Nix host/user/config/package consumers contain no separate Stalwart CLI
  selection to override. Keep destination desktop overlays, Rust policy and
  public package membership; import no private AW adapter.
- New regression needs later carry-back. Remaining Stalwart lifecycle/helper
  differences remain a separate later source unit; this is not mail migration
  acceptance or a claim of helper parity.

## History and policy boundaries

- Migration row 90: 4978 planning-only events (2803 deletions, 2174 additions,
  one modification). Current presence: 2797 retired in both trees, 2174
  source-only, six target-only, one different. Preserve all six destination Rust
  custody paths; no source plan owner authorizes rewriting nix history.
- Shared AGENTS common/monorepo sections, ignore header and plan specification
  already match. Keep repository suffixes, local queue and source-only archives.
  CLAUDE shim, docs index and TODO-SPEC remain absent in both current trees.
- Private Codex protocol/config/store, deployment records and 28GiB host policy
  remain local. All 5113 events have explicit dispositions; missing paths are
  recorded as retirement, never extant equality.
- Preserve all 24 Pi catalog records, newer shared pins and exact input locks.
  Source-only Codex extension stays excluded; no Tailscale downgrade or held z
  patch application. Incus downgrade safety still blocks deployment.

## Validation

- Five focused checks passed: CLI selection, helper (22 synthetic tests),
  provisioning, repository configuration and no-IFD lint. Selection/helper/
  provisioning derivations ran locally; unrelated valid outputs may be reused.
- Old-overlay negative control fails the new repository-pin assertion; the
  candidate selects the exact pinned derivation on all three registered systems.
  Constructor environment assertions evaluate on all three; no ARM/Darwin
  execution is implied.
- Real x86_64 CLI realization reused an existing pinned 1.0.14 output. Local
  `--version` and `--help` verify URL/user/password flags and environment names;
  no connection, credentials or mail-service operation.
- All-system no-build evaluation passed with IFD disabled: 88 x86_64 Linux and
  87 aarch64 Linux checks, none on Darwin. Existing registrations remain; only
  the new CLI check is added on each Linux system.
- Seventy non-maintenance package derivations are unchanged across three
  systems. Six fmt/lint wrappers rebind identical script bytes to changed
  repository-source paths; remaining wrapper text, tool inputs and environment
  are identical. This is not an all-76 derivation-identity claim.
- Initial scratch job 552 attempted to encode an unapplied Nix function as JSON.
  Explicit application corrected the harness; no production assertion or test
  was relaxed. Corrected graph/control/CLI/all-system run: job 554.
- Final checkpoint gate: canonical offline fmt/lint, repeated five checks,
  exhaustive path/mode/ownership and preserved input/queue/main/source guards.
  No live acceptance, fresh compilation, deployment or global parity claim.

## Path dispositions

- adapted-shared-binding: 1.
- already-adopted-local-identity: 7.
- already-adopted-local-membership: 1.
- already-adopted-local-suffix: 1.
- already-present: 8.
- retained-destination-custody: 6.
- retained-input-policy: 1.
- retained-product/host-policy: 23.
- retained-source-coordination: 2223.
- retired-layout/history: 2842.
