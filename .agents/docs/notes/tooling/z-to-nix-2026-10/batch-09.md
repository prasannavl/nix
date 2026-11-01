# Reverse batch 09

- Frozen source rows 201–225; combined queue rows 284–308.
- 25 commits, no merges; 177 first-parent events across 127 paths.
- Base `9df471370a4f4695c2e7a3dbcf1abcb6cc774984` (signed batch 08 checkpoint).
- Current comparison: z `8ad96801`; frozen endpoint/310-entry queue unchanged.
- Code-bearing review stays staged; neither batch 08 nor 09 is approved for
  main.

## Commit review

| Row | Source     | Decision                                                                                                                                                                                             |
| --- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 201 | `bf2f9007` | Private recovery allocation remains source evidence, not renewed test or provider authority.                                                                                                         |
| 202 | `7bd54294` | Private completion review stays within accepted criteria; definition lookup does not imply a runtime audit.                                                                                          |
| 203 | `3541b0aa` | Private final-suite allocation remains historical source planning.                                                                                                                                   |
| 204 | `d1399a2f` | Private full-read proof couples protocol optional coverage, observed EOF checks, excerpt projection and legacy deserialization; no partial transplant.                                               |
| 205 | `239f13da` | Private controller KillMode=mixed preserves child cleanup before the existing 25s cgroup kill; its diagnostic VM is not a destination service.                                                       |
| 206 | `fc9def60` | Private capacity-slot retirement evidence does not authorize API calls, data removal or limit changes here.                                                                                          |
| 207 | `94522fe2` | Private search refinement retains contextual-read gates; narrow budget previews bind dispatch and fake-provider tests together.                                                                      |
| 208 | `d4af9a4e` | Private unread candidates survive refinement; preserve penultimate contextual read and final answer reservations coherently.                                                                         |
| 209 | `63037456` | Private repeated-search correction binds a retained candidate read rather than another free-form search.                                                                                             |
| 210 | `4bc0ddfe` | Private empty-search scope is path-local, with provider descriptions and generated schemas kept together.                                                                                            |
| 211 | `9458e971` | Private crash-recovery acceptance waits for intents/scratch cleanup after container removal; no production behavior or destination test deletion.                                                    |
| 212 | `318f9afa` | Private completion-control fixture correction stays local; no copied acceptance claim.                                                                                                               |
| 213 | `1925ab1b` | Private final development acceptance is historical evidence, not newly executed destination coverage.                                                                                                |
| 214 | `4451116b` | Private managed snapshot outer/inner identities admit schema2 alongside schema1/current, retaining unknown-schema rejection and integrity/protocol checks.                                           |
| 215 | `8272612f` | Private deployment/outage records and rollout playbook grant no authority for this task.                                                                                                             |
| 216 | `034649b9` | Private host-reboot recovery remains historical; no live reboot or acceptance probe.                                                                                                                 |
| 217 | `0652b47c` | Private workflow plans/archive/results/samples remain source-owned; preserve destination coordinator queue.                                                                                          |
| 218 | `f084309e` | Private ChatGPT selection requires current generation, available model and matching ready proof; browser race/error coverage remains coupled.                                                        |
| 219 | `57ef25ee` | Private model dropdown preserves saved selection on another model rejection, generation fences and metadata hold behavior.                                                                           |
| 220 | `098958e0` | Private cloud-provider qualification plan preserves credential and database custody; not implementation authority here.                                                                              |
| 221 | `4a5edc08` | Private accepted external-provider scope stays source-local, with no provider/profile activation.                                                                                                    |
| 222 | `a0458d4e` | Port coherent shared routing, managed override exclusion, NUL fields, fresh-checkout runtime, completion, stable terminal cleanup and their tests; keep identity policy and migration ledgers local. |
| 223 | `009bc1dc` | Grouped selector helper/projection/tests and design already match current destination; no duplicate port.                                                                                            |
| 224 | `dfb5fb80` | Scoped cache policy/config plumbing/tests and design already match; preserve destination cache ownership and inputs.                                                                                 |
| 225 | `417a9e93` | Owned live-proxy helper/module/tests and rollback warning already match; downgrade blocker remains, no deployment.                                                                                   |

## Shared contract and adaptations

- Named routes: `auto|default|cf|ts`; explicit CLI/environment choice precedes
  developer override. Managed auto uses exact tracked self identity; direct
  developer auto chooses cf. Missing named routes fall back by whole route,
  never by mixing transport fields. Explicit cf/ts must affect selected paths.
- Validate tracked route schema even when overlays mask fields. Exact inventory
  keys precede resource aliases; reject ambiguous identity, unknown jumps and
  dormant-route cycles. No failure-driven route switching or Tailscale probe.
- Developer overlay paths bind to invocation cwd before reexec/clone. Explicit
  invalid input fails early; absent sibling remains absent after fresh checkout.
  Managed/controller and CI inventory reject developer overlays; service
  options, serialized deployment policy and child environments change together.
- NUL-framed JSON decoding retains multiline/trailing-newline SSH metadata
  across deploy, CI and role contexts. Routed CI requires known-host material;
  synthetic key fixtures do not authorize credential use or host-key bypass.
- Stable terminal frames batch/coalesce updates, update changed rows, preserve
  redirected output and restore cursor/synchronization on failure/panic/signal.
  Two old whole-dashboard redraw expectations are replaced by changed-row/no-op
  assertions; other destination regression declarations remain present.
- Shared route data lives at
  `pkgs/tools/abird-host-manager/tests/fixtures/named-routes.json`: three cases,
  schemaVersion 2, structurally identical to the source ledger block. Rust
  includes its own package fixture; the Bash Nix test copies only that JSON. No
  extra Cargo workspace/dependency or root lock policy change is needed.
- Do not import `TEST-DISPOSITION.md`, private migration/parity assertions or
  `test_nixbot_abird.py`. Keep all 307 prior generic Bash test declarations and
  the exact Pvl sibling; candidate has 332 generic declarations. No legacy
  retirement, engine cutover or package membership change.
- Keep destination inventory, host/cache policy, exact inputs/Dotlink/Tailscale
  pins, MIT identity and Rust composition/lock policy. Grouped access, scoped
  cache and live proxies already match; Incus downgrade still blocks deployment.

## Executed validation

- Canonical offline format/lint and staged diff checks passed on the initial
  implementation. Native agent: 160 library tests; manager: 400 library tests,
  72 compatibility-CLI tests and all integration suites. No ignored failures.
- Nine registered Nix checks passed after fixture isolation: both Rust package
  test derivations, Bash helper/runtime, agent/manager/Nixbot service checks,
  repository configuration and lint no-IFD. Bash ran 333 tests (332 generic and
  the retained Pvl sibling). Source-filtered Rust compilation includes the
  standalone JSON; no source-boundary or workspace-membership bypass.
- Nix sandbox initially exposed `ci_trigger_rejects_named_override_environment`
  relying on the enclosing Git checkout. It now initializes its own temporary
  repository, clears inherited Git selectors, pins child cwd and uses an absent
  Nix executable to ensure rejection precedes evaluation. The original expected
  rejection remains; production code unchanged. Actual sandbox retry passed.
  Carry this generic fixture correction back with the standalone route data.
- Six controls fail against the actual base Bash implementation and pass against
  the candidate. Two same-interface assertions expose truncated known-host
  text/lost proxy command and false resource-alias ambiguity. Other controls
  detect missing new interfaces/options or field decoding; they are not six
  independent end-to-end transport proofs.
- Changed package-owned Nix files passed Statix/Deadnix separately from root
  diff lint. No toolchain, assertion, hash, IFD or remote-builder bypass.
- Git-aware all-system no-build/no-IFD evaluation passed: 179 checks (90 x86
  Linux, 89 ARM Linux, 0 Darwin), none added or removed. An initial ARM
  child-parity invalid source path was resolved by ordinary recursive package
  derivation instantiation and uncached parity evaluation; no
  foreign-architecture build or IFD enabling.
- Package membership unchanged: 64 identical derivations; 12 intentional changes
  restricted to agent/manager/Nixbot Linux outputs and fmt/lint wrappers. These
  are synthetic/native/sandbox tests and evaluation, not live connection,
  fleet-build, credential, activation or production acceptance.

## Final checkpoint gates

- Re-run canonical format/lint, focused checks and all-system evaluation on this
  reported tree, then exhaustive path/type/mode/index/master/ref guards.
- Keep batch 08's sixteen staged paths and both masters unchanged. Checkpoint
  the coherent shared unit and review evidence separately, signed, with exact
  independently previewed unit trees and final original-index equality.
- Managed `configOverride` / `config_override_path` removal is intentional
  authority tightening; obsolete serialized fields fail closed. Destination
  tracked service callers need no additional host change. This is not rollback
  or deployment certification; Incus downgrade remains blocked.
- No private product tests, source migration-ledger acceptance or Rust Nixbot
  cutover. Global byte/type/mode/presence audit and carry-back remain later.

## Path dispositions

- adapted-shared-fixtures: 1.
- already-present: 21.
- ported-shared-routing-output: 34.
- retained-coherent-private-product: 23.
- retained-destination-coordination: 2.
- retained-host-policy: 3.
- retained-identity-test: 1.
- retained-repository-policy: 1.
- retained-source-evidence: 90.
- retired-owned-ledger-layout: 1.
