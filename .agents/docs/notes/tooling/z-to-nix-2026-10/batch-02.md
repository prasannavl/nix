# Reverse batch 02 — source rows 26–50

- Global frozen rows 109–133: 25 commits, two merges, 1,098 first-parent path
  events / 638 unique paths. Full ledger: `batch-02-paths.tsv`.
- Review worktree `worktrees/z-to-nix-02`, branch `review/z-to-nix-02`.
  Base/main: `472863a548f972f0e723a7e9049d340fb50a2cd3`; user approved landing.
- Source reference `8ad96801`; frozen source queue and prior reports/events
  remain unchanged. Signed logical integration and clean batch-01/02 worktree
  removal are authorized; later batches remain staged pending main approval.

## Commit dispositions

| Reverse / global | Source     | Disposition                               | Rationale                                                                                                                                                                                                                                                  |
| ---------------- | ---------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 26 / 109         | `9dda9ee4` | retained evidence                         | Shared foundation plan/guidance is present; preserve nix handoff and retired coordination paths, not z operational additions.                                                                                                                              |
| 27 / 110         | `bcbdd99c` | local incident retained                   | Fleet rollback/data-skew incident belongs to z; no destination rollout or state migration is inferred.                                                                                                                                                     |
| 28 / 111         | `76b1cc65` | already adopted / retained evidence       | Shared NixOS VM qualification note matches; preserve repository handoff and historical qualification limits.                                                                                                                                               |
| 29 / 112         | `684b9e0a` | already adopted / relocated               | Closure, compile-context, source-boundary, base and composition machinery survives under lib/flake/rust. Current common implementations/fixtures match; do not resurrect flat paths or re-enable policy.                                                   |
| 30 / 113         | `8808883b` | already adopted / relocated               | Immutable mirror tooling and validator live under lib/flake/rust/mirror with matching current bytes/modes.                                                                                                                                                 |
| 31 / 114         | `544e1881` | already adopted / relocated               | Optional qualification is split between language-owned machinery and named repository recipes. Old rust-unit-spike paths remain retired; no new VM/reuse certification.                                                                                    |
| 32 / 115         | `97481dfb` | already adopted / local records           | Keep nix self-reference guidance, including its additional programmatic Git-fetcher section; retain destination done-capsule custody records.                                                                                                              |
| 33 / 116         | `be2a9490` | mixed: portable policy support            | Port ordinary cargoLockContentsFor and its synthetic fixture through current Rust paths. Preserve root workspace/locks/inputs/composition and Pvl identity adapter. Current Codex server is private-agent-contract-coupled, not a standalone generic unit. |
| 34 / 117         | `f4c3967a` | private closeout retained                 | Private agentic phase-4a closeout/formatting does not authorize its products, root dependencies or historical plan import.                                                                                                                                 |
| 35 / 118         | `9e0c5a55` | private planning retained                 | Phase-4b planning remains local; portable Rust guidance is adapted separately without importing Abird composition defaults.                                                                                                                                |
| 36 / 119         | `fdc23588` | mixed merge; no duplicate replay          | First-parent merge repeats private phase work plus the shared lock-policy seam. Account every path; apply the surviving portable unit once.                                                                                                                |
| 37 / 120         | `1933dd4a` | retained custody/history                  | Preserve nix publication evidence and immutable receipts; source custody claims do not prove new runtime acceptance.                                                                                                                                       |
| 38 / 121         | `7d37ef3c` | already adopted                           | Optional closure/base/source/mirror routes already reject Cargo.lock.nix before policy/member payload reads. Keep those fail-closed guards while porting only ordinary-route support.                                                                      |
| 39 / 122         | `7bba93e2` | already adopted / relocated               | Native fixture formatting survives in the canonical Rust tests; retain executable modes and source-root behavior.                                                                                                                                          |
| 40 / 123         | `aca69314` | already adopted / relocated               | Static Nix fixes survive extraction; no policy change or weakened assertion is needed.                                                                                                                                                                     |
| 41 / 124         | `5ec426d2` | local historical wording                  | Retained-event byte clarification belongs to historical custody evidence; do not recreate or rewrite receipts.                                                                                                                                             |
| 42 / 125         | `d9381239` | mixed: guidance only                      | Abird-agent module defaults/tests are private identity/product policy. Adapt reusable source-input/composed-package guidance without introducing that module or changing Pvl callers.                                                                      |
| 43 / 126         | `210e8550` | already adopted / complete coherent paths | Language factories, Rust tooling/fixtures, façade and consumers already use canonical paths. Add only the missing ordinary lock seam and three git-lock fixtures; preserve local overlays and identity tests.                                              |
| 44 / 127         | `94cba1c6` | mixed: portable rootless guidance         | Private ChatGPT providers, products, backup policy and credentials stay local; secret paths are filename-only. Port only the shared rootless Podman mount-namespace warning.                                                                               |
| 45 / 128         | `46e1bb17` | private deployment receipt                | Deployment/custody evidence remains local; no provider, backup or credential activation.                                                                                                                                                                   |
| 46 / 129         | `3b46c197` | private historical formatting             | Formatting of private phase records does not create a destination implementation obligation.                                                                                                                                                               |
| 47 / 130         | `ee205ebf` | private application repair                | Callback-scope repair belongs to the absent private app; do not extract a partial authentication unit or activate profiles.                                                                                                                                |
| 48 / 131         | `9e570007` | private deployment receipt                | Keep callback-repair deployment evidence local; it is not destination live acceptance.                                                                                                                                                                     |
| 49 / 132         | `96bad370` | mixed merge; no duplicate replay          | First-parent merge repeats private application/credential changes and rootless guidance. Retain private paths and apply the shared paragraph once.                                                                                                         |
| 50 / 133         | `5cca73ca` | already adopted repair / complete seam    | Source/vendor installation, caller-hook order, explicit-lock behavior and real fallback fixture already match. Combine them with ordinary implicit sidecar resolution; add cross-constructor regression assertions without root lock-policy adoption.      |

## Selected unit and retained boundaries

- Port the ordinary `cargoLockContentsFor` implementation and Git-lock fixture
  through current language-owned paths. Listed absent sources fail evaluation;
  explicit lock overrides still take precedence. Source/vendor installation
  stays after caller patches and before the ordinary setup-hook comparison.
- Add six synthetic regressions beyond the source test: no-policy byte
  preservation, fallback installation, Crane package/vendor equality, isolated
  source/vendor equality, Trunk package/vendor equality and explicit override.
  These are later carry-back obligations, not current byte-parity claims.
- No root `Cargo.lock.nix`, private AW input, workspace/member change, new
  credential access, compiler switch or composition-default change. Optional
  closure/base/source/mirror rejection stays enabled and tested.
- Keep Pvl `repo-checks.nix`, identity tests, overlays, exact inputs/catalog and
  the independently advanced Dotlink declarations. Codex server is coupled to
  private agent policy/patches; preserve the existing destination Codex wrapper.
- Port reusable Rust guidance with repository-owned defaults, and the rootless
  Podman namespace warning. Keep nix self-reference guidance and local custody
  evidence; never rewrite historical receipts or infer fresh deployment proof.

## Validation

- Pure toolchain/ordinary-policy evaluation: 97 assertions passed, IFD disabled.
- Thirteen focused checks pass: eleven Rust contracts, repository config and
  no-IFD lint. Existing real fallback source/vendor/compile fixture included;
  realization may reuse valid outputs (job496).
- Native tooling: 9 layout + 53 mirror + 59 qualification-unit + 28 freshness
  tests pass (149 total; job497). No optional VM qualification was run.
- Old main helper fails the new implicit source/vendor alignment regression
  while all 97 candidate assertions pass (job504).
- Seventy package derivations match baseline across all three systems. Six
  fmt/lint wrappers differ only in repository-source script paths; script bytes,
  otherwise identical wrapper text and tool inputs match. An initial all-76
  identity assertion was too broad; do not claim it passed.
- Final canonical/preservation gate precedes signing/integration. No current
  global compatibility claim.
- No private source fetch, profile activation, live host/container mutation,
  optional VM qualification, forced fresh Cargo-reuse proof or deployment.

## Path disposition counts

- already-present: 261.
- ported-fixture: 3.
- ported/adapted: 10.
- retained-identity-adapter: 10.
- retained-local-evidence: 31.
- retained-private-coupling: 10.
- retained-product/host-policy: 76.
- retained-repository-policy: 19.
- retained-secret-boundary: 18.
- retired-history/layout: 238.
- superseded-relocation: 422.
