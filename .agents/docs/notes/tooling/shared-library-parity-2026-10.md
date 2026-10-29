# Shared library parity — 2026-10

## Scope and verdict

Audit of tracked `lib/` paths in Abird (`a0458d4e`) and Pvl (`b714b723`),
including working files. Compare file bytes, symlink targets and modes; do not
follow fixture symlinks. No private-key material was read.

- 519 Abird paths; 556 Pvl paths; 493 common paths.
- 459 common files match; **34 differ**; no mode differences.
- All 34 already differ between committed HEADs. Pvl's Pi source/updater files
  additionally contain ongoing, preserved edits. The cache/proxy work did not
  introduce these forks.
- All 13 shared cache/access files and all nine Incus files match, including the
  new live-proxy implementation.
- **Shared implementation parity is feasible; containment is only partial.**
  Some differences are deliberate policy, but others are unported fixes or
  features. Neither repository is universally the newer/correct source.
- Literal whole-tree equality is not a sensible copy operation: identity tests,
  installer targets, hardware choices and package selections must remain owned
  by their repositories. Move policy out of generic files, or explicitly mark
  small repository-owned entrypoints as exceptions.

Classification of the 34 common-file differences:

| Class                                                | Files |
| ---------------------------------------------------- | ----: |
| Repository-owned composition/data                    |     2 |
| Intentional policy embedded in generic modules/tests |     8 |
| Independently refreshed release pins                 |     5 |
| Pi catalog/resolver feature divergence               |     2 |
| Generic feature/fix/test drift                       |    16 |
| Comment-only drift                                   |     1 |

## Per-file assessment

Paths below are relative to `lib/`. Commit references identify relevant history,
not proof that the latest edit introduced every differing line. Proposed parity
work is **not implemented** by this audit.

1. **`ext/pi/sources.nix` — catalog/features.** Pvl refreshed versions, expanded
   the extension catalog and pinned registry dependency graphs; Abird retains
   `pi-codex-limit`. Pvl also has an unfinished `pi-tool-manager` addition.
   Catalog data is localized, but package availability and user selection must
   not be confused. Merge a supported catalog plus wrappers, retaining Abird's
   entries, or inject repository-owned catalogs. Do not overwrite ongoing work.
   Validate package/dependency builds and user selections together.
2. **`ext/pi/update.sh` — catalog/features.** Pvl adds registry graph
   resolution, platform filtering and many hard-coded package cases; Abird lacks
   this mechanism (`83dc06df`, subsequent Pvl updates). Selection and mechanics
   are mixed, so containment is incomplete. Share a tested resolver and derive
   its inventory from catalog data. Validate dependency conflicts, optional
   native packages, supported platforms and update/build round trips with
   item 1.
3. **`ext/prism-llama-cpp/sources.nix` — release pin.** Abird
   `prism-b10777-e3de715`; Pvl `prism-b10826-c9c34bc` (`6da867b1`). Only version
   and CUDA/ROCm hashes differ. Cleanly localized data, not an architectural
   fork. Agree a release and validate both supported GPU archive variants.
4. **`ext/stalwart-cli/sources.nix` — release pin.** Abird 1.0.13; Pvl 1.0.14
   (`6da867b1`), with corresponding per-platform hashes. Localized release data.
   Align after CLI package and helper compatibility checks; not a substitute for
   the separate recovery fix below.
5. **`ext/tailscale/sources.nix` — release pin.** Abird 1.104.1; Pvl 1.104.4
   (`b714b723`), including source/vendor hashes. Localized data. Agree the
   release, build it and evaluate transport consumers; do not change live
   networking as part of a parity edit.
6. **`ext/vscode/sources.nix` — release pin.** Abird 1.142.0; Pvl 1.143.1
   (`6da867b1`), including desktop/server archives and hashes. Localized data.
   Align the complete pin set and check each supported platform/package.
7. **`flake/repo-checks.nix` — repository composition.** Abird injects Abird
   topology, Gap3 and product check promotions; Pvl injects its identity suite.
   **Intentional and cleanly contained:** this file explicitly declares itself
   repository-owned; shared assembly receives it as an argument. Keep the seam,
   or move the entrypoints outside `lib/` for literal generic-tree parity.
   Preserve check-name collision detection and both complete check inventories.
8. **`flake/rust/default.nix` — generic feature.** Abird normalizes selected
   `Cargo.lock` source lines using optional package-owned `Cargo.lock.nix`; Pvl
   reads the lock verbatim. The policy is already package-local, but the
   reusable mechanism is missing in Pvl. Port the optional behavior, not private
   package policy. Check Crane/non-Crane paths, source/vendor lock equality and
   unchanged behavior when no policy exists.
9. **`flake/rust/tests/toolchain.nix` — generic coverage.** Abird tests the
   source-filtered lock; Pvl lacks that assertion and fixture binding. Carry it
   with item 8 and the three Abird-only `fixtures/git-lock/` files. This is not
   a legitimate repository identity test difference.
10. **`flake/stack/package.nix` — cosmetic.** Pvl's `24ff8a5f` explains why an
    injected package set must not force `nixpkgs.lib`; executable expressions
    already match. Choose one comment. Existing injected-package-set evaluation
    tests suffice; no host behavior needs to change.
11. **`hardware.nix` — role policy.** Abird retained TRIM while removing
    physical workstation defaults during `560b1370`; Pvl also enables firmware,
    I2C, Bluetooth, fwupd, power profiles and UPower. Intentional role
    differences, **not cleanly isolated** in a generic file. Move
    physical/desktop choices to host/profile modules; compare effective options
    for every current importer.
12. **`hardware/nvidia.nix` — generic workaround.** Pvl `e174ce21` defaults
    `kernelSuspendNotifier` off to retain the systemd suspend path for affected
    open NVIDIA drivers. Abird lacks the workaround; other code matches. Share
    the fix if supported by both pins, or express a hardware-specific choice in
    profiles. Check option compatibility and affected GPU/suspend behavior; byte
    equality alone cannot prove the hardware fix.
13. **`installer/config/default.nix` — repository data.** Abird has an empty
    physical-target map; Pvl selects GNOME/persistence/user settings and
    concrete disks/UUIDs. Legitimate and localized to a config file, though
    placed under `lib/`. Keep it an explicit policy exception or inject
    `config/`-owned data. Never copy Pvl disk targets into Abird. Evaluate
    image/target contracts without writing disks.
14. **`locale.nix` — desktop policy.** Both use the same locale/timezone; Pvl
    additionally forces the GeoClue demo agent and BeaconDB provider. Historical
    commentary also differs. Move geolocation policy to Pvl's desktop profile;
    shared locale mechanics can match. Verify effective desktop/server options
    and preserve the intentionally disabled automatic-timezone behavior.
15. **`network.nix` — resolver policy.** Pvl `ee18ba08` adds Cloudflare DNS,
    DNS-over-TLS, DNSSEC, empty fallback and `~.` routing defaults. Abird only
    enables resolved here. This is deliberate policy inside generic networking,
    not harmless version drift. Extract an explicit resolver profile; preserve
    private/split DNS and Tailscale link exceptions. Do not impose public DNS
    policy on Abird merely to make files equal.
16. **`services/abird-host-agent/default.nix` — controller contract drift.** Pvl
    emits `config_override_path`; Abird's routing checkpoint `a0458d4e` removed
    it from managed-controller configuration. Not repository identity data.
    Reconcile with the actual host-agent runtime/schema, not a Nix-only copy.
17. **`services/abird-host-agent/options.nix` — controller API drift.** Pvl
    still exposes `nixbotDeploy.configOverride`; Abird removed that option in
    the same checkpoint. Port the agreed managed-controller contract with item
    16; audit callers and test rejection/isolation of developer-local overrides.
18. **`services/abird-host-manager/default.nix` — controller contract drift.**
    Pvl retains controller override options/wrapper environment; Abird instead
    sets `NIXBOT_EXECUTOR_KIND=managed` on reconciliation units. This affects
    execution semantics, not just packaging. Align with both native runtimes,
    fleet routing and item 30; preserve repository authentication settings.
19. **`services/kanidm/tests/default.nix` — generic test isolation.** Abird
    `d45c03d5` supplies `pkgs.hello` for a shape-only CLI assertion, avoiding an
    unnecessary pinned Kanidm build. Pvl still forces the real package. Share
    the stub for this shape check; retain separate functional CLI tests.
20. **`services/nginx/compose/compose.yaml` — release pin.** Abird nginx 1.30.5;
    Pvl 1.30.6 (`de954948`). Only the image tag differs. Localized pin; align an
    agreed image and validate compose rendering/service compatibility. No reason
    to fork the remaining compose implementation.
21. **`services/nix-builder-gc-coordination/default.nix` — capacity policy.**
    Abird's constrained CI defaults are jobs/cores/connections **1/12/8**
    (`81e7dceb`, `21598f25`); Pvl raises jobs/connections to **16/16** without
    that explicit core cap (`44b8512a`). Both are intentional, but host sizing
    does not belong in duplicated GC-lock mechanics. Move sizing into host or
    builder-role configuration; retain identical lease/GC coordination.
22. **`services/pi-web/default.nix` — service policy.** Pvl `0584085e`
    hard-codes `PI_WEB_DISABLE_MCP=1`; Abird does not. Move that choice to Pvl's
    service configuration using the environment seam, rather than disabling MCP
    for both repositories. Verify generated service environments and preserve
    the intended capability difference.
23. **`services/stalwart/helper.sh` — missing generic reliability fix.** Abird
    `fbd92e70` fixes certificate-renewal recovery: separate lifecycle/apply
    locks, database-owner checks, startup-only mode, restoration/readiness,
    cleanup failures and automated versus interactive stdin. Pvl predates it.
    **Port as a bundle**, not an intentional fork: helper, tests, lifecycle VM
    and service startup/renewal callers outside `lib/`. New startup callers use
    `apply-startup`; copying only the helper can violate lifecycle ordering.
24. **`services/stalwart/tests/default.nix` — missing generic coverage.** Abird
    registers the real lifecycle VM added by `fbd92e70`; Pvl does not. Carry the
    registration and Abird-only `tests/lifecycle.nix` with item 23.
25. **`services/stalwart/tests/fake_podman.py` — missing fixture behavior.**
    Abird models running containers, early recovery exit, stdin and apply
    failures; Pvl mostly reports stopped state. Needed for item 23's failure
    guarantees, not a repository policy distinction. Port with the tests it
    supports.
26. **`services/stalwart/tests/test_helper.py` — missing regressions.** Abird
    verifies lock release, restoration, original error preservation, removal
    failures, startup isolation and stdin handling. Pvl lacks those cases. Port
    with items 23–25; run both helper and real rootless lifecycle tests.
27. **`sudo.nix` — security/usability policy.** Pvl sets
    `timestamp_timeout=720`: **720 minutes / 12 hours**, despite a comment
    saying ten minutes. Abird omits that override after its server-profile
    split. Move the Pvl choice to an explicit host/user policy and correct the
    comment; do not silently extend fleet sudo caching. Compare rendered
    sudoers.
28. **`swap-auto.nix` — missing generic reliability fix.** Pvl `d20d63c7`
    retains successful Btrfs provisioning state with `RemainAfterExit` and
    disables the start-rate limiter so repeated mount requests do not
    wedge/re-run the chain. Abird lacks it. Port with items 33–34 and validate
    existing, missing and newly provisioned swap subvolumes.
29. **`systemd.nix` — power policy.** Pvl limits `systemd-suspend` to three
    starts per 30 minutes; Abird does not. Move that desktop/host choice out of
    generic systemd defaults. Compare rendered units; do not introduce suspend
    limits into fleet hosts merely for parity.
30. **`tests/abird-host-manager.nix` — controller contract coverage.** Pvl tests
    override propagation; Abird tests managed executor identity and absence of
    an override. Follow the reconciled runtime contract from items 16–18, not a
    blind union of contradictory expectations. Run wrapper/unit/native fleet
    integration tests together.
31. **`tests/default.nix` — test registration drift.** Abird adds Stalwart
    lifecycle coverage; the Prism x86-only check is otherwise just ordered and
    commented differently. Share the union of generic tests with their fixtures,
    retaining architecture guards. Product/identity promotions stay in item 7,
    not this common registry.
32. **`tests/nix-builder-gc-coordination.nix` — misplaced policy assertions.**
    The test hard-codes each repository's differing capacity values from
    item 21. Share tests of GC/lease mechanics and configurable sizing; assert
    actual fleet/Pvl capacities in their respective identity tests. Both
    effective host configurations must remain unchanged after extraction.
33. **`tests/swap-auto-vm.nix` — missing regression coverage.** Pvl counts
    provisioning runs across activation, mount-chain restart and reboot, proving
    it runs once per boot when needed. Abird lacks those assertions. Port with
    item 28 and execute the VM, not only its Nix evaluation.
34. **`tests/swap-auto.nix` — missing module assertions.** Pvl asserts the new
    no-rate-limit and retained-success settings; Abird does not. Port with items
    28 and 33; retain existing ordering/private-mount assertions.

## Files present in only one repository

There are also **26 Abird-only / 63 Pvl-only** library paths. These are not part
of the 34 differing common files:

- Clean identity boundaries: `flake/tests/{abird,pvl}/` and Abird's
  `services/kanidm/tests/gap3.nix`. Keep each suite with its repository.
- Missing generic coverage: Abird's three Rust git-lock fixtures and Stalwart
  lifecycle VM must accompany their implementations when ported.
- Package availability: Abird's `pi-codex-limit`; Pvl's expanded Pi wrappers,
  Neovim/GNOME packages and other desktop integrations. Reconcile catalog scope
  before claiming whole-library parity; availability need not imply enabling.
- Pvl's device/desktop/profile modules and images, Abird's Sway and Excalidash
  modules: inspect separately if whole-tree parity is desired. Presence alone
  does not establish either a bug or a clean policy boundary.

## Recommended convergence order

1. **Reliability bundles:** Stalwart Abird -> Pvl; swap Pvl -> Abird; assess the
   NVIDIA workaround against both hardware/pin sets. Preserve their tests and
   external consumers.
2. **Generic contracts:** Rust optional lock policy Abird -> Pvl; coordinated
   host-control runtime/module/test alignment; Kanidm test isolation; common
   test registry/comment normalization.
3. **Policy extraction:** capacity, resolver, hardware/geolocation, sudo,
   suspend and Pi-web environment into explicit host/profile/service settings.
   Snapshot effective configurations before/after; changing file organization
   must not change intended host behavior.
4. **Catalog/pins:** agree release pins, then reconcile Pi's supported catalog,
   dependency resolver and wrappers after the current Pvl work is complete.
5. **Enforce scope:** byte/mode checks for an explicit shared implementation
   set; small documented repository-owned exceptions. No blanket tree copying or
   filename-only success metric. Both canonical gates, affected unit/VM/package
   tests and representative host evaluation are required for each bundle.

No unrelated source files were synchronized. This is an assessment and proposed
sequence, not evidence that the proposed ports or live behaviors were tested.
