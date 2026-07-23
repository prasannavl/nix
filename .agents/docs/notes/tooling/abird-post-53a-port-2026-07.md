# Abird Post-53A Port 2026-07

## Scope

- Local starting point: `7499cdff` on `master`.
- Previous Abird audit anchor: `53a66371`.
- Initial refreshed Abird source tip: `2f48876e` on 2026-07-18.
- Audit window: `53a66371..2f48876e`, 38 commits in source order.
- Latest Abird source tip: `547f9163` on 2026-07-23. The remote rewrote the five
  commits after `6a5ad32f`; the replacement commits are patch-equivalent,
  followed by seven genuinely new commits.
- Port worktree: `worktrees/abird-post-53a-port-20260718`.
- Post-parity Abird source tip: `bdfe404f` on 2026-07-23, with two new commits
  after the shared parity landing.
- Follow-up worktree: `worktrees/abird-post-cad-port-20260723`.

The audit was commit-by-commit before grouping. Final implementation used the
source-tip file state for cumulative shared units because several later commits
intentionally replace intermediate Podman and nixbot lifecycle designs.

## Per-Commit Ledger

| Commit     | Subject                                          | Disposition                                                                                                                                                                                         |
| ---------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `41216c24` | `fix(nixbot): gate unhealthy settling`           | Cleanly ported in the cumulative nixbot health unit. Unhealthy runtime is settling only while independent work is still transitioning.                                                              |
| `5855828f` | `fix(deploy): harden activation verify`          | Adopted in two shared units: Podman timeout/restart-policy handling and nixbot activation health. Source docs were adapted locally.                                                                 |
| `8f51ad5e` | `fix(podman-compose): serialize rootless starts` | Adopted through the cumulative Podman transaction unit. Its intermediate lock shape was superseded by later lifecycle commits.                                                                      |
| `2cda3e0f` | `fix(update): skip current prefetches`           | Already ported by local `7507005d`. The three shared updater scripts are byte-identical; the local unit additionally covers GNOME extensions.                                                       |
| `78919dad` | `style: format excalidash helper`                | Skipped. The Excalidash helper and its consumer were intentionally absent after the preceding audit.                                                                                                |
| `4efa3988` | `fix(podman-compose): bound runtime recovery`    | Cleanly ported through final Podman source-tip parity. Intermediate monitor/repair behavior was subsequently simplified.                                                                            |
| `9ba2cd73` | `fix(novu): gate apps on healthy dependencies`   | Skipped. Abird Novu host topology has no local consumer.                                                                                                                                            |
| `80686e9e` | `fix(nixbot): fail closed on incomplete deploys` | Cleanly ported in the cumulative nixbot unit, after its required Podman expected-unit and mutation-marker contracts.                                                                                |
| `d53cb78e` | `docs: format deploy lifecycle notes`            | Adopted through formatting of the local documentation set; foreign incident notes were not copied.                                                                                                  |
| `e4ecbce7` | `style(nixbot): align health query arguments`    | Cleanly ported with the nixbot source-tip state.                                                                                                                                                    |
| `70f42b1b` | `docs(tooling): add upstream patch audits`       | Adopted. The two reusable patch audit/publication notes were added and indexed locally.                                                                                                             |
| `f7c9dd80` | `fix(migrations): avoid duplicate runtime apply` | Cleanly ported byte-for-byte in migration-manager code and shared profile tests.                                                                                                                    |
| `769295b5` | `refactor(podman-compose): simplify lifecycle`   | Adopted through the cumulative Podman unit; later graph/transaction commits supersede its intermediate implementation.                                                                              |
| `6766fbba` | `fix(forgejo): bound CLI retry attempts`         | Cleanly ported byte-for-byte with its helper tests.                                                                                                                                                 |
| `6c8a7cc9` | `fix(abird-corp): route OIDC internally`         | Skipped. Abird Gatus/Jitsi topology only. The reusable verification foundation is included elsewhere.                                                                                               |
| `2c4767ed` | `fix(nixbot): retain activation output`          | Cleanly ported in the cumulative activation transport unit.                                                                                                                                         |
| `2febd94d` | `docs: record deploy lifecycle handoff`          | Skipped as a historical Abird implementation plan. The implemented final design is documented locally instead.                                                                                      |
| `1b6076ef` | `fix(systemd): isolate managed service starts`   | Partially adopted. Shared Podman, migration tests, and nixbot graph discovery were ported; Abird Ollama and host incident surfaces were skipped.                                                    |
| `037b645e` | `refactor(podman): simplify mutations`           | Cleanly ported as the explicit transaction/runtime verification foundation, including the lifecycle VM test.                                                                                        |
| `548ab539` | `fix(nixbot): verify compose runtime`            | Cleanly ported with expected-runtime health inventory and activation-progress tests.                                                                                                                |
| `3ea7de13` | `fix(penpot): probe backend listener`            | Skipped. No local Penpot consumer; generic `verifyCommand` support is ported.                                                                                                                       |
| `62da8291` | `docs(podman): record lifecycle redesign`        | Adopted into local Podman, migration, lifecycle, and design docs. Abird incident history was excluded.                                                                                              |
| `e18f73d6` | `docs(podman): plan Quadlet backend`             | Skipped as a plan because the next source commit implements and supersedes it.                                                                                                                      |
| `8b63f7f7` | `feat(podman): isolate backend lifecycles`       | Partially adopted, code-complete. The shared source-tip unit and generic function-instance default hardening are now byte-identical with the Abird parity worktree; foreign incidents were skipped. |
| `bc29c773` | `fix(podman): describe TLS probe endpoints`      | Skipped at call sites. Abird Kanidm and Gap3 metrics declarations are absent locally; backend-neutral TLS probe support is present through `8b63f7f7`.                                              |
| `e173014b` | `fix(opendesign): make tmpfs writable`           | Skipped. No local OpenDesign consumer.                                                                                                                                                              |
| `b5f86e11` | `style(docs): apply Markdown formatting`         | Adopted through the local docs formatting pass rather than copying foreign notes.                                                                                                                   |
| `4d1c2a8b` | `style(shell): apply shfmt formatting`           | Adopted with the final Quadlet helper and Forgejo helper bytes. No standalone unit was needed.                                                                                                      |
| `cc91ba61` | `test(podman): consolidate service declarations` | Cleanly ported in the Podman module test parity set.                                                                                                                                                |
| `5d58a1a4` | `fix(podman): contain runtime mutations`         | Cleanly ported byte-for-byte across Compose, Quadlet, image preparation, and tests.                                                                                                                 |
| `528b4366` | `fix(nixbot): contain deploy failures`           | Partially adopted. Shared nixbot code/tests/module were ported; the D-Bus transport policy was adapted into `hosts/common/pvl.nix` rather than copying the Abird host module.                       |
| `19525260` | `fix(corp): contain service failures`            | Skipped. Abird Penpot and Zulip host settings have no active local consumer.                                                                                                                        |
| `6a5ad32f` | `docs(podman): record deploy containment`        | Adopted into local Podman/nixbot documentation without copying the Abird incident plan.                                                                                                             |
| `18f574f6` | `fix(zulip): suppress lifecycle admin noise`     | Skipped. Abird Zulip backend and audit data are not locally consumed.                                                                                                                               |
| `3fdefd34` | `feat(lifecycle)!: unify start controls`         | Cleanly ported as one atomic shared unit across Incus, Podman Compose, `systemd-user-manager`, and tests. `startConcurrency` replaces `startParallelism`; `-1` means unlimited.                     |
| `fd923d3a` | `fix(podman): defer contended image pulls`       | Cleanly ported byte-for-byte for both Compose and Quadlet paths.                                                                                                                                    |
| `0dbd8de1` | `fix(nixbot): contain deploy transport fanout`   | Cleanly ported with per-domain deploy capacity, proxy-process cleanup, completion, and tests.                                                                                                       |
| `2f48876e` | `feat(host-manager): add fleet selectors`        | Adopted and reconciled. Shared host-manager mechanics/tests are byte-identical; Pvl and Abird defaults, generated-host imports, and deployment-host mapping now live in repository-owned policy.    |

## 2026-07-23 Rewritten-Tip Follow-up

The refreshed `abird/master` replaced the five commits after `6a5ad32f`.
Patch-equivalence, rather than ancestry, identifies the already-audited work.

| Commit     | Subject                                        | Disposition                                                                                                                                                          |
| ---------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `eee16cf3` | `chore(ollama): bump to 0.32.0`                | Adopted across all five Pvl ROCm and generic Ollama image declarations on `pvl-x2`, `pvl-a1`, and `pvl-l5`.                                                          |
| `d2699a9a` | `perf(ollama): use f16 KV cache`               | Skipped after adaptation review. Pvl retains `q8_0` because its 64K-256K contexts make F16 materially more expensive in VRAM and system memory.                      |
| `92722e93` | `feat(robin): add file attachments`            | Skipped. Pvl has no Robin packages, Cargo workspace members, manifest entries, bot deployment, or secrets consumer.                                                  |
| `1110ff46` | `fix(zulip-robin): render queue messages`      | Skipped with the Robin attachment unit; it is an inseparable follow-up and has no local consumer.                                                                    |
| `e5933d4f` | `fix(zulip): suppress lifecycle admin noise`   | Already audited as patch-equivalent to `18f574f6`; skipped because Pvl has no matching Zulip lifecycle-audit consumer.                                               |
| `f84c8cbb` | `feat(lifecycle)!: unify start controls`       | Already ported; patch-equivalent to `3fdefd34`.                                                                                                                      |
| `e9f0a2bd` | `fix(podman): defer contended image pulls`     | Already ported; patch-equivalent to `fd923d3a`.                                                                                                                      |
| `1a0fb41b` | `fix(nixbot): contain deploy transport fanout` | Already ported; patch-equivalent to `0dbd8de1`.                                                                                                                      |
| `d924246b` | `feat(host-manager): add fleet selectors`      | Already ported and policy-separated; patch-equivalent to `2f48876e`.                                                                                                 |
| `620d446e` | `feat(hosts): schedule Incus startup waves`    | Adopted locally: `pvl-x2` starts two guests per wave, with `abird-nest` and `gap3-gondor` before the two Pvl lab controllers. Abird host-role policy was not copied. |
| `d3592291` | `style(docs): apply formatter`                 | Adopted through formatting the local capacity, host-manager, ledger, and index documents; repository-specific wording was retained.                                  |
| `547f9163` | `feat(mail): add hello mailing list`           | Skipped. The list domain, members, group data, Stalwart deployment, and observability note are Abird-specific; no shared mail implementation changed.                |

## 2026-07-23 Selector-Scope Follow-up

| Commit     | Subject                                        | Disposition                                                                                                                                                                                          |
| ---------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `f81509a9` | `feat(tooling): separate group and host scope` | Cleanly ported byte-for-byte across host-manager, nixbot, completion, and both test suites. Pvl declares no groups, `defaultGroup`, or `defaultHosts`, so no inventory policy adaptation was needed. |
| `bdfe404f` | `docs(tooling): align selector guidance`       | Partially adopted. Generic selector semantics and Pvl command examples were updated; exact adopted and skipped logical units are listed below.                                                       |

For `bdfe404f`, the local index, signed-build-cache design, Bash-completion and
host-manager notes, GCP bootstrap, nixbot deploy and key-rotation playbooks, and
`docs/hosts.md` were adopted with Pvl examples and policy. The Abird
active-stack note; the absent host-selection-exclusions, consolidated nixbot
operations, and signed-build-cache handoff notes; the service-registry DNS
playbook; both Abird-stack/nixbot implementation plans; and the Gondor-to-Nest
migration script's Abird-specific command change were skipped.

## Logical Port Units

1. Podman Compose and Quadlet lifecycle, transaction containment, runtime
   verification, image-pull deferral, and the full shared test subtree.
2. Unified Incus, Podman, and `systemd-user-manager` start controls.
3. Nixbot activation authority, retained output, runtime health, failure
   containment, and deploy-domain transport fan-out.
4. Migration-manager runtime ownership and tests.
5. Forgejo bounded CLI retry behavior and tests.
6. Host-manager fleet selectors adapted to the local Pvl ownership boundary.
7. Local D-Bus activation-transport policy and durable documentation.
8. Pvl Ollama `0.32.0` image adoption while retaining the local `q8_0` capacity
   policy.
9. Pvl-x2 two-wide, readiness-settled Incus startup waves with explicit
   controller priority tiers.
10. First-class group workflow scope, exact singular hosts, and plural host
    filtering across nixbot, host-manager, completions, tests, and local
    operator documentation.

## Parity Contract

Byte-identical to the Abird `shared-tooling-parity-20260718` worktree after the
parity completion:

- all touched files under `lib/podman-compose/**`;
- `lib/incus/default.nix`, `lib/incus/lib.nix`, and
  `lib/incus/tests/module.nix`;
- the touched `lib/systemd-user-manager/**` code and tests;
- the touched migration-manager, Forgejo, and global `lib/tests/**` files;
- the touched nixbot implementation, module, and tests;
- the nixbot Bash completion;
- the host-manager shared script, package wiring, and tests;
- the three updater scripts from `2cda3e0f`.

Intentional divergence:

- `pkgs/tools/host-manager/policy.nix` is repository-owned: Pvl selects the
  `pvl` stack and its physical-host profile; Abird selects `abird` and its
  common stack modules.
- Each repository's host-manager `policy.nix` owns its deployment-host
  projection: Abird maps Gondor/stage/dev names and Pvl uses identity mapping.
- `hosts/common/pvl.nix` applies the activation D-Bus restart policy at the
  local shared-host boundary.
- `hosts/pvl-x2/services/portainer/default.nix` corrects the local edge-tunnel
  and HTTPS endpoint metadata used by generated health probes.
- host declarations and documentation otherwise use local ownership and
  examples.

## Validation

- Shell syntax and direct helper suites passed for Podman, Forgejo,
  `systemd-user-manager`, migration-manager, host-manager, and nixbot. After
  parity completion, host-manager passed 30 tests and nixbot passed 161 tests.
- After the selector-scope follow-up, shell syntax passed again, host-manager
  passed 31 tests, and nixbot passed 174 tests. The matching Nix sandbox helper
  and package builds passed; the first nixbot helper run crossed a one-second
  timing boundary in an existing fast-path assertion and the immediate fresh
  build passed unchanged.
- Nix checks passed for isolated flake evaluation, Forgejo, Incus, the Podman
  helper/module/conversion suites, both Podman lifecycle VMs, Incus profiles,
  and both `systemd-user-manager` suites.
- Full `pvl-x2`, `pvl-a1`, and `pvl-l5` NixOS toplevel builds passed. These
  builds verify the function-instance defaulting, Portainer endpoint, two-wide
  Incus wave, and Ollama `0.32.0` adaptations above.
- The shared Incus module check passed, and evaluated `pvl-x2` policy reports
  concurrency `2`, priority `10` for `abird-nest` and `gap3-gondor`, and
  priority `20` for `pvl-vlab` and `pvl-vlab-1`.
- The source-tip host-manager test derivation lacked its runtime `nix`,
  `openssh`, and `alejandra` inputs. The parity completion adds those shared
  inputs, and all 30 host-manager tests pass in the Nix build sandbox.
- Changed Markdown and Nix were formatted, `git diff --check` passed, and the
  final mechanical parity audit found 310 byte-identical common files and 21
  explained, established repo-owned platform/package differences under `lib/**`
  and `pkgs/**`, including the package-owned host-manager policy. There was no
  unexplained shared-file divergence.
- A final refresh confirmed the rewritten `abird/master` tip at `547f9163`.
- The selector-scope refresh confirmed `abird/master` at `bdfe404f`. Its five
  touched shared implementation/test files are byte-identical, and the
  repository-wide common `lib/**` and `pkgs/**` result remains 310 identical
  files plus the same 21 explained divergences.
