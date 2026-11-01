# Reverse batch 01 — source rows 1–25

- Global frozen queue rows 84–108; 25 commits, including one merge; 247
  first-parent path events. Exhaustive path dispositions: `batch-01-paths.tsv`.
- Target/base: nix `e74e990c`; current source reference: z `8ad96801`.
- Worktree: `worktrees/z-to-nix-01`; branch: `agent/z-to-nix-01`.
- Signed commits stay in this stack; neither master is integrated.

## Commit dispositions

| Reverse / global | Source     | Disposition                               | Rationale                                                                                                                                                                                                                                                                                                                   |
| ---------------- | ---------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 / 84           | `bd288952` | already adopted                           | Both entry guards are present. progress.rs and terminal_mode.rs exactly match source bd288952 blobs; later renderer changes belong to their later source units.                                                                                                                                                             |
| 2 / 85           | `75603b24` | already adopted                           | Host-agent rsync check input is present; current shared constructor bytes/mode match z.                                                                                                                                                                                                                                     |
| 3 / 86           | `929aa60f` | already adopted                           | Git-aware self-reference helper, installer/updater callers and lint guard already exist. Event-format exclusions are a separate later delta.                                                                                                                                                                                |
| 4 / 87           | `19206c30` | superseded                                | Constructor/updater match; nix already selects Tailscale 1.104.4 with the newer unstable input. Never downgrade to historical 1.104.1 or apply the z-only final-update hold here.                                                                                                                                           |
| 5 / 88           | `5173e352` | adapted carry-forward                     | Historical Pi refresh is present. Port the forward-reviewed data-driven, fail-closed updater and 16 generic regressions from z bc7b5797. Preserve nix catalog, versions and intentional Codex omission.                                                                                                                     |
| 6 / 89           | `56729d7e` | adapted carry-forward                     | Profile-tool PATH already exists. Port explicit default-enabled MCP option/tests from z e2538400; set mcp.enable=false in both existing Pvl callers to preserve MCP policy; raw unit PATH differs only through revision-stamped nixos-version.                                                                              |
| 7 / 90           | `12123f06` | already adopted                           | Current Prism, Stalwart CLI and VS Code pins match; no historical downgrade.                                                                                                                                                                                                                                                |
| 8 / 91           | `8ca2ddb2` | already adopted                           | Ignored-tree pruning and all three discovery/child-ref/CLI regression files match current z.                                                                                                                                                                                                                                |
| 9 / 92           | `5e61e5d7` | already adopted                           | Registry-confirmed image tag lookup and its generic suite match current z.                                                                                                                                                                                                                                                  |
| 10 / 93          | `d2e9c8aa` | already adopted                           | Bladebro constructor, source and updater match; existing manifest exports it. Retain other repository package memberships.                                                                                                                                                                                                  |
| 11 / 94          | `b6811999` | retired / local history                   | Revdiff implementation is absent in both current trees. Keep its z incident/history note local; do not revive the package.                                                                                                                                                                                                  |
| 12 / 95          | `55bf432f` | already adopted / policy retained         | Transport hold helper and all three service assignments already exist. Retain Pvl resolved/DoT/DNSSEC policy; unchanged source does not prove every live host applies these overrides.                                                                                                                                      |
| 13 / 96          | `3826595b` | already adopted                           | Rust seam review markers in helper/package stack already match.                                                                                                                                                                                                                                                             |
| 14 / 97          | `3b3544b5` | local historical receipt                  | Do not transplant z historical broad-port receipt or revive retired docs index. Record this new review independently; carry forward the safer shared cross-sync playbook.                                                                                                                                                   |
| 15 / 98          | `db1792d4` | already adopted / local evidence retained | Generic foundation documents and surviving shared notes match; obsolete design/plan paths remain retired. Keep nix corrected Cargo-workspace prose and its qualification record; do not copy Abird corp incident evidence.                                                                                                  |
| 16 / 99          | `a5fb7372` | superseded / adapted comment              | Current inputs/pins supersede the old refresh; agenix follows cleanup and pnpm_10_latest are present. Keep exact nix lock graph, including Dotlink. Adopt only the host-neutral OpenDesign explanation; no constructor behavior change.                                                                                     |
| 17 / 100         | `98c45677` | local policy / carry-forward test         | Do not import the old Abird EOL host waiver or incident note. Add z 296b9302 generic CLI metadata regression for the already-present narrow EOL filter; unrelated CVEs remain asserted.                                                                                                                                     |
| 18 / 101         | `a2c69e26` | already adopted / local notes             | Prompt bytes already match. Do not change user selection or transplant personal operational notes.                                                                                                                                                                                                                          |
| 19 / 102         | `f18f0613` | local historical formatting               | Only z Kanidm incident formatting; leave local history untouched.                                                                                                                                                                                                                                                           |
| 20 / 103         | `36bb183e` | private planning                          | Private agentic application/contract delivery planning only; preserve destination ownership and retired plan state.                                                                                                                                                                                                         |
| 21 / 104         | `96397795` | private planning merge                    | First-parent merge delta repeats private planning from row20; no shared code delta.                                                                                                                                                                                                                                         |
| 22 / 105         | `071e6bb1` | retired private planning                  | Formatting of a now-retired host-control plan; no current shared implementation delta.                                                                                                                                                                                                                                      |
| 23 / 106         | `e1974d32` | private planning                          | Private AW kernel assessment/plan pin, not a shared package update; leave its historical records local.                                                                                                                                                                                                                     |
| 24 / 107         | `e091fa28` | ported and hardened                       | Port the generic Excalidash constructor/helper together, including container-root migration. Review found ignored OpenSSL failure could persist an empty secret: fail closed on generation failure/empty output/existing empty values. Add eight synthetic regressions and constructor build check; no host/app deployment. |
| 25 / 108         | `21fe3af5` | host policy retained                      | All 35 Abird/Gap3 container declarations are host-owned; no Pvl image or instance changes.                                                                                                                                                                                                                                  |

## Coherent additions beyond the historical path list

- Forward-review carry-forward: Pi updater tests, explicit MCP module/tests,
  Kanidm CLI metadata test and safer cross-sync playbook. These are identified
  adaptations, not extra source commits appended to the frozen queue.
- Pi Web: two Pvl caller declarations preserve the old effective MCP-off
  behavior; no authentication, exposure or host selection change.
- Excalidash: add its required generic constructor, eight offline tests and
  shared registration. No Abird host declaration, live database, real container,
  credential/profile activation or unrelated state is touched.
- New Excalidash hardening is a reverse-review adaptation to carry back in the
  later normalization pass; do not claim current byte equality with z.
- Shared check registry adds only the four owned registrations; preserve every
  existing check and repository identity home.

## Validation

- Canonical format/lint passed initially (job444). Its first build attempt found
  the new fake executable used unavailable `/usr/bin/env` in the Nix sandbox;
  fixed the fixture to use its actual Python interpreter, not a production
  change or weaker assertion.
- Twelve focused Nix checks passed after the fixture repair (job446); native Pi
  regressions: 16; updater discovery/ref/report regressions: 85 (job452).
  Excalidash: eight synthetic tests plus packaged-constructor build; the
  original helper fails all three new secret-failure cases (job447).
- Real pinned Pi tool-manager 0.1.1 prefetch/build passed in an isolated
  fixture: all 24 catalog records remain semantically equal after forced update,
  followed by a byte-identical no-op (job449). Metadata was fixture data;
  prefetch/build were real and may reuse valid outputs. No activation.
- Actual Pvl MCP environment/package/user/bind/exposure/origin policy is
  unchanged. Raw unit bytes differ only in system PATH: its sole changed package
  is nixos-version carrying clean-vs-dirty configurationRevision. Compare the
  baseline with only revision metadata aligned in an evaluation counterfactual:
  full units, package lists and policy match (job455). No production override,
  assertion relaxation or raw-unit equality claim.
- All-system no-build evaluation passed with IFD disabled (job461), after
  ordinary uncached instantiation of 76 package and 173 check derivations.
  Package-owned Statix/Deadnix checks passed. This is evaluation, not ARM/Darwin
  execution or a full system build.
- The final twelve focused checks passed on the final helper/test bytes
  (job462). Pi's 16 native regressions and old-updater negative control passed
  (job456). Final formatting/lint and owned-path preservation gate precede
  signing; the branch history records the exact signed tip.
- Integrate the shared Pi Web option and following Pvl caller-policy commit
  together; the batch boundary preserves MCP-off policy, not the intermediate
  shared-default commit alone.
- No whole-fleet build, real database migration, runtime MCP acceptance or
  renderer requalification claimed here. Historical renderer adoption is proven
  by exact original blobs; later renderer changes have their own unit.
