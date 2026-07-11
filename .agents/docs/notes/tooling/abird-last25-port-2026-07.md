# Abird Last-25 Port, July 2026

## Scope

Reviewed the newest 25 commits on `abird/master` at `88cd27bb`, starting from
local `master` at `3a7a840d`.

Goal: port shared `lib/` and `pkgs/` behavior with byte-for-byte parity where
the same files exist in both repos, while skipping Abird-only hosts, secrets,
plans, and topology notes.

## Ported Logical Units

- Event-driven user reconciles: `lib/systemd-user-manager/**` now matches Abird
  for queued starts, deferred restart markers, provider verification, derived
  manager timeouts, dry-activate missing-user skips, and tests.
- Hardened Podman Compose lifecycle: `lib/podman-compose/**` now matches Abird
  for synchronous compose readiness, `timeoutReadySeconds`, `postStart`,
  `startStateStallSeconds`, rootless lifecycle locks, retryable first starts,
  rootless idmap migration, image-pull hardening, and tests.
- Dynamic service apply helpers:
  `lib/services/{forgejo,kanidm,ollama,stalwart}/**` and `lib/tests/default.nix`
  now match Abird for bounded app-native apply/recovery helpers and tests.
- Nixbot activation and lock recovery: `pkgs/tools/nixbot/nixbot.sh` and tests
  now match Abird for activation transport verification, control-master-free
  probes, held-lock auditing, `clear-remote-locks --force`, rootless Podman lock
  discovery, sequential health checks, and deploy image-pull prechecks.
- Shared service-module cleanup: `lib/flake/service-module.nix` adopts the Abird
  shared removal of `ConditionUser` from generated user services.

## Local Adaptations

- Abird docs were not copied wholesale. Local docs were updated in
  `docs/podman-compose.md`, `docs/systemd-user-manager.md`,
  `.agents/docs/design-patterns/podman-compose-instance.md`,
  `.agents/docs/notes/services/systemd-user-manager.md`,
  `.agents/docs/notes/services/user-services-platform.md`, and
  `.agents/docs/notes/nixbot/deploy-system.md`.
- Abird host/service declarations, scoped Abird secrets, and Abird deployment
  notes remain skipped.
- The `timeoutStableSeconds` key remains recognized only as backward-compatible
  JSON metadata in `lib/systemd-user-manager/helper.sh` tests; the Nix option
  and docs use `timeoutReadySeconds`.

## Commit Ledger

- `38416cbd fix(auth): use alias app launchers`: skipped. Abird-only
  Forgejo/Kanidm app launcher and host docs; no shared `lib/` or `pkgs/`
  surface.
- `405f0d93 refactor(nixbot): share remote script builder`: already represented
  locally by `ce485a63`; retained in final byte-parity nixbot file state.
- `042f268c style(nixbot): apply shell formatting`: already folded into local
  nixbot refactor; retained in final byte-parity nixbot file state.
- `19b22d9c fix(ollama): share model pull helper`: already ported locally for
  shared Ollama helper/tests; retained in final byte-parity service-helper
  state.
- `da6cdce6 fix(systemd-user-manager): reset stale failures`: already ported
  locally by `1068e8c1`; retained in final byte-parity systemd-user-manager
  state.
- `36f1f138 test(systemd-user-manager): stabilize start waits`: already ported
  locally by `ac503ed6`.
- `1da0e618 fix(systemd): make reconciles event driven`: adopted under the
  event-driven user reconciles logical unit.
- `0d9b02b2 fix(podman): harden compose lifecycle`: adopted under the hardened
  Podman Compose lifecycle logical unit.
- `eb7c060f fix(services): harden dynamic applies`: adopted under the dynamic
  service apply helpers logical unit.
- `e4ac594d fix(hosts): converge scoped app starts`: partially adopted. Only the
  shared `lib/flake/service-module.nix` `ConditionUser` removal was ported.
  Abird hosts and encrypted scoped secret filenames were skipped as Abird-owned
  topology/state.
- `33470fcd fix(nixbot): verify activation fanout`: adopted for
  `pkgs/tools/nixbot/**`. Abird `hosts/nixbot.nix` group ordering was skipped as
  topology-specific.
- `df487140 docs(deploy): record reconciler design`: adapted into local docs
  listed above. Abird host/secrets/nixbot consolidated notes were not copied.
- `86b2ae9a docs(secrets): plan backend stratification`: skipped. Abird-specific
  planning artifact; no local PVL plan requested.
- `9252b7b6 style(docs): format markdown`: skipped as standalone. Relevant local
  Markdown was formatted after adaptation.
- `d7fba2a7 fix(podman-compose): narrow start locks`: adopted under the hardened
  Podman Compose lifecycle logical unit.
- `ec675a28 fix(nixbot): surface active start workers`: adopted as part of final
  nixbot parity, though local behavior was already close before the port.
- `1b5fae55 fix(podman-compose): close rootless fd in children`: adopted under
  Podman Compose and nixbot lock-recovery units.
- `71389d4d fix(podman-compose): wait for compose starts`: adopted under
  event-driven user reconciles and hardened Podman Compose lifecycle. Local docs
  were updated for the `timeoutReadySeconds` rename.
- `5777eb2e fix(stalwart): isolate recovery runtime`: adopted for shared
  `lib/services/stalwart/**`. Abird Stalwart host timeout edits were skipped.
- `cdaeb959 fix(nixbot): harden deploy recovery checks`: adopted for
  `pkgs/tools/nixbot/**`; Abird docs were adapted locally instead of copied.
- `1b12fdf4 style(docs): format deploy notes`: skipped as standalone. Local docs
  were formatted after adaptation.
- `1f968108 fix(stalwart): clarify recovery trap`: adopted with the Stalwart
  recovery runtime unit.
- `bbdb1ce0 fix(podman-compose): harden deploy image pulls`: already mostly
  sourced from this repo's local `173689bf`, then retained in final Abird-parity
  Podman Compose and nixbot state.
- `a65aabe9 docs(podman-compose): update pull boundary note`: already
  represented locally by `e88ef872`; no additional copy needed.
- `88cd27bb fix(podman-compose): satisfy lint`: already represented locally by
  `3a7a840d`; retained in final parity state.

## Byte-Parity Audit

The final shared target set should be byte-identical to `abird/master` for:

- `lib/podman-compose/**`
- `lib/systemd-user-manager/**`
- `lib/services/forgejo/**`
- `lib/services/kanidm/**`
- `lib/services/ollama/**`
- `lib/services/stalwart/**`
- `lib/tests/default.nix`
- `lib/flake/service-module.nix`
- `pkgs/tools/nixbot/**`

Intentional non-parity remains for Abird host inventories, Abird stack files,
Abird encrypted secret payloads, Abird app packages outside this repo's adopted
shared package scope, and Abird docs/plans whose local equivalents have
different ownership.
