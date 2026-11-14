# Abird shared port — November 2026

Status: **integrated into `master` in signed logical commits** after explicit
user approval. No push or deployment performed.

## Boundaries

- Original destination audit baseline:
  `2d9f5d5caefd80c1955b298475289d6bc697649a`.
- Current integration base: `e7f3ef479c42c8cfa89668230782809cb3a3fb3e`. Three
  concurrent main commits removed Kilo CLI/VSCode and updated Dotlink to 0.17.0.
  Their eight paths are disjoint from this port; all 294 owned files survived a
  non-forced detached checkout byte-for-byte. Those destination changes remain
  preserved by the main-worktree integration.
- Frozen source: `070011e2923ebdb16370bbfbba31876c47584002`.
- Report window:
  `13dafcdedeb2362ae670b65437a5a26af677f75a..070011e2923ebdb16370bbfbba31876c47584002`.
- Previous port: 227 commits through `b1a0f5bb4f57e2a7c6ea2648deed412c42d33171`;
  new tail: 225 commits. All 452 source SHAs are accounted individually,
  including merges and their first-parent deltas.
- Reviewed snapshot: `worktrees/abird-port-20261114`, detached at the
  integration base. Its original staging remains unchanged as a review backup.
  Delivery is in the main worktree on `master`.
- Prior receipt consolidation preserves the identical tree:
  `4b2d4c71acf382e6fb4799ab41bf934391e04e1b` and
  `e6bc13b91a44e26751de97a3c66e118eb7ac7407`. Historical checkpoint ancestry
  disappearing from main is not evidence of a missing port.

## Main integration

Ten signed implementation commits, followed by this audit-receipt commit:

| Commit      | Logical unit                                     |
| ----------- | ------------------------------------------------ |
| `505b64fa6` | fix(git): isolate lint and hide encrypted diffs  |
| `82acd41b8` | fix(rust): preserve cold Cargo source metadata   |
| `bb74168e7` | fix(tooling): bound lint and accept fmt target   |
| `0334828c0` | feat(ai): add typed inference bindings           |
| `161587584` | feat(fleet): add native owned-build runtime      |
| `51e7fa088` | fix(nixbot): delegate agents before bootstrap    |
| `78a47d653` | feat(fleet): wire opt-in owned-build services    |
| `7b3e32e33` | fix(opendesign): preserve saved provider choices |
| `15d6c7f49` | feat(graphiti): separate chat and embed bindings |
| `d56640ca0` | fix(cloudflare): enforce stable-key validation   |

Test registrations are committed with their features. The runtime precedes the
Nixbot frontend; the frontend precedes fleet workflow VM registration. Final
non-report bytes/modes match the reviewed snapshot; parity counts and both
manifest fingerprints are unchanged. See [verification](verification.md) for
main-worktree checks and the limits of reused test evidence.

## Reading the evidence

- [Commit ledger](commit-ledger.md): every commit, its logical-unit dispositions
  and reasons; [machine-readable ledger](commit-ledger.json).
- [Parity audit](parity.md) / [complete path manifest](parity.json): bytes,
  types, modes, symlinks, relocations and every retained exception.
- [Verification](verification.md): executed gates, independent review closures,
  corrected intermediate failures and explicit qualification limits.
- [Owned-build interface](owned-build-interface.md): neutral reference for the
  experimental default-off interfaces; not a rollout recipe.

### Outcome counts

| Source window                                  | Ported | Adapted | Already adopted | Skipped | Superseded | Commits |
| ---------------------------------------------- | -----: | ------: | --------------: | ------: | ---------: | ------: |
| Previous session, historical outcomes retained |      2 |      16 |              40 |     166 |          3 |     227 |
| New source tail                                |     11 |      18 |              17 |     172 |          7 |     225 |

A commit-level port/adaptation can exclude identity, host or historical units;
its ledger row spells out those partial decisions. Prior-session outcomes are
not counted as new imports.

Current raw shared-path audit: **984/1,039 common paths byte/type/mode exact**
(527 library + 457 package paths). All 55 common differences, 527 source-only
and 78 candidate-only paths are individually classified. `lib/incus/` is **12/12
exact**; `lib/services/ai/` is **19/19 exact**. No unclassified generic transfer
gap remains. Deliberate correctness adaptations are not disguised as byte
equality. Kilo's newly approved destination removal accounts for one formerly
equal file becoming source-only; it is not reintroduced for parity.

- Prior-session verdicts summarize immutable October content/path reviews. Their
  227 commits and 7,474 first-parent path/status events were rechecked against
  Git. Historical runtime/equality claims are not silently presented as new test
  results; current shared-tree verification is separate.
- New-tail audits inspected commit contents, dependency boundaries and both
  endpoint trees. Product changes were reviewed for scope, not certified for
  correctness or copied into this public repository.
- Secret-bearing paths were classified by metadata only. Source operational
  receipts do not constitute destination validation or rollout permission.

## Logical units

1. **Fleet runtime and service integration:** complete generic owned-build
   executor, native preparation/acquisition bridge, retained planning and
   cancellation, generated caller profiles, Nixbot delegation and regression
   coverage. Includes independent observer-reattachment, resolved-ref worktree
   and no-realization-replay fixes. Existing `auto` continues to select Nix;
   executor/controller/capture remain default-off. No host opts in here.
2. **AI library:** pure and typed inference declarations/resolution, checked
   consumer binding, credential-reference/file primitives, menu selection and
   tests. Existing hosting, model pins and legacy consumer interfaces remain. No
   Pvl app migration or source-specific cloud/account policy is implied.
3. **Rust and tooling:** cold Cargo source metadata/filter preservation,
   formatter `.` handling, bounded root lint evaluation and regression tests;
   lazy-source assertion adapted to the Pvl child-flake suite.
4. **Shared packages:** OpenDesign saved-choice protection and independently
   bound Graphiti chat/embedding clients, with compatibility/test
   reconciliation.
5. **Git safety:** clear inherited `GIT_EXEC_PATH` before lint; prevent Git from
   displaying encrypted-secret patches. The latter is a separately identified
   pre-window gap (`b7339eec3cbe6cf7531afe6737ec417febb67eb0`), not an extra
   invented commit in the 452-row queue.
6. **Cloudflare validation:** recover missing stable-key uniqueness checks in
   four variable-definition files while retaining encrypted input channels and
   stronger local checks. Fix both lineages' ineffective `can(alltrue(...))`
   predicates with fail-closed `try(..., false)`. Resource addresses, defaults,
   topology and the previously skipped Access resolver remain unchanged.

## Retained ownership and policy

- MIT/public identity, root inputs/lock, Cargo workspace membership/lock, host
  topology, secret material, credentials and deployment state stay local.
- Preserve newer Pi/Prism/Tailscale/VS Code and desktop package pins; do not
  apply the source's held unstable/Tailscale patch or change restart policy.
- Preserve device, desktop, timezone/RTC, DNS, Numtide cache, sudo/suspend,
  installer and 16-lane builder policy. Identity tests and composition manifests
  remain repository-owned.
- Preserve 13 child-flake workspace-policy injections rather than importing
  Abird's product-workspace default-off choice.
- Preserve management-style external relocations and consumer-local AWL/Z-Push
  binding (`48b56e1d`). Sway functionality already lives in Pvl's desktop/WM
  modules; a duplicate module is not a missing feature.
- Retain the explicitly documented optional patched-Cargo qualification lane.
  The stock-only retirement portion of `230f38141` is a source policy change;
  stock Cargo 1.95.0 has not thereby acquired the ordering fix. Port its
  independent lazy-source assertion, not the policy deletion.
- Source-only application fixture fetchers do not become required by the shared
  AI library. Existing Pvl app images, saved-state behavior and multi-device
  menus need their own migration qualification, not copied Abird adapters.
- Private products and previously excluded package membership remain excluded.
  The queue tools and EDI example are technically shareable but were explicitly
  skipped previously; their absence is not mislabeled as intrinsic privacy.

## Qualification boundary

Byte equality is implementation evidence, not installed-service acceptance. The
native bridge is bound to Nix 2.34.9 / ABI 3. Current destination inputs provide
that version; unsupported versions leave the adapter unavailable. Namespaces,
Landlock, daemon/cgroup fencing, signed copyback, cancellation and rollback need
their corresponding executable tests; no live acceptance follows from this port.
Gate outcomes, review closures and remaining operational limits are in
[verification](verification.md); the complete byte audit is in
[parity](parity.md). No deployment, reverse port, commit or push is implicit.
