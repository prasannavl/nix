# Abird Shared Port Parity, June 2026

This port reviewed the newest 50 commits on the `abird` remote at `dcbe0a7e` and
adopted only shared units into this repo.

Byte-identical with Abird after the port:

- `lib/incus/default.nix`
- `lib/incus/lib.nix`
- `lib/podman-compose/default.nix`
- `lib/flake/secrets.nix`
- `lib/flake/service-module.nix`
- `lib/flake/service-registry.nix`
- `lib/flake/stack/lib.nix`
- `lib/services/nginx/ingress-composer.nix`
- `lib/services/fail2ban-helper/default.nix`
- `lib/services/fail2ban-helper/fail2ban-helper.py`
- `lib/services/observability/vector-agent.nix`
- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `pkgs/tools/nixbot/default.nix`
- `pkgs/tools/nixbot/nixbot.sh`

Repo-local adaptations:

- `hosts/nixbot.nix` moved from the old `globals` / `defaults` shape to `config`
  / `config.hostDefaults`, preserving the existing PVL hosts and deploy policy.
- `lib/stacks/pvl-registry.nix` now gives PVL the same stack-owned registry
  shape as Abird, adapted to the existing `pvl-x2` service topology and
  `p7log.com` domains.
- `lib/stacks/pvl-dev.nix` intentionally adopts Abird's scoped stack pattern for
  PVL. Existing hosts still consume `stacks.pvl`; the new profile provides an
  explicit future dev identity.
- `data/secrets/pvl/default.nix` accepts `scope`, uses scoped secret filenames,
  and registers PVL CA recipients.
- `data/secrets/default.nix` imports PVL secret recipients for unscoped and
  `dev` scopes.
- PVL service modules now use `stack.secrets.serviceKey` instead of manually
  appending `*.key.age`, so scoped stack profiles resolve secret filenames
  consistently.
- `pkgs/tools/host-manager/host-manager.sh` keeps the local machine-profile
  split instead of Abird's default `incusLxc` profile. Generated Incus hosts are
  registered with `machineProfiles.incusLxc`; other generated hosts keep
  `machineProfiles.vm`.
- `pkgs/README.md` was corrected to point package registration at
  `pkgs/manifest.nix`.

Skipped or intentionally divergent:

- Abird host inventories, workflow group defaults, stack replicas, scoped secret
  payloads, and `lib/stacks/abird*` / `lib/stacks/gap3.nix` remain Abird-owned.
- Abird app/service package families such as `pkgs/bots`, `pkgs/srv`,
  `pkgs/labs`, `pkgs/web`, and `pkgs/ext/gcp-cloud-run` were not adopted.
- `pkgs/tools/postgres-queue/` and `pkgs/tools/sqlite-queue/` were explicitly
  removed from the port scope.
- `pkgs/support/nats-streams/default.nix` and `pkgs/tools/data-migrator` remain
  repo-specific.

## Follow-up Deploy Retryability Port

Ported from Abird `master` after `61d5da7e`:

- `nixbot` now lets NixOS `switch-to-configuration` own activation serialization
  and reports native lock contention with transient-unit and journal context.
- `systemd-user-manager` stop-phase waits treat inactive user managers and
  missing user buses as already stopped.
- `podman-compose` writes compatible staging state before runtime file staging
  or Compose startup, so failed first starts remain retryable.
- Shared Stalwart apply helpers can resolve a primary domain by name and rewrite
  staged plan/userdata domain tokens before apply/reconcile work.

Skipped as Abird-specific:

- `hosts/abird-corp/services/stalwart/default.nix`
- Abird consolidated deployment notes that do not exist in this repo

## July 2026 Last-50 Port

Reviewed the newest 50 commits on `abird/master` at `a61b7aa8` from local base
`703eefd8`.

Adopted as shared byte-parity units:

- `lib/flake/stack/lib.nix` and `lib/flake/tests/default.nix`: scoped CA source
  paths, host-path defaults for native Postgres/NATS clients, and centralized
  `timeouts` handling.
- `lib/podman-compose/default.nix`, `lib/podman-compose/helper.sh`, and
  `lib/podman-compose/tests/**`: supervised child PID/process-group cleanup and
  provider-neutral tunnel metadata.
- `lib/services/nginx/default.nix` and
  `lib/services/nginx/ingress-composer.nix`: stream timeout rendering, edge-auth
  cache policy headers, and absolute oauth2 sign-in redirects.
- `pkgs/tools/nixbot/nixbot.sh`, `pkgs/tools/nixbot/nixbot.bash`, and
  `pkgs/tools/nixbot/tests/test_nixbot.py`: local `clean` and remote
  `clear-remote-locks` actions.
- `pkgs/ext/kanidm-server/default.nix`, `pkgs/ext/bulwarkmail/**`,
  `pkgs/ext/stalwart-server/**`, and `pkgs/ext/z-push/**`: portable
  package/image updates and compatibility patches from the Abird mail/auth
  stack. The Stalwart `calendar-imip-method-fallback-policy.patch` and
  `imap-starttls-auth.patch` files are semantically equivalent to Abird but have
  trailing whitespace removed to satisfy this repo's whitespace gate.

Adopted older shared prerequisites to keep the copied helpers coherent:

- `lib/services/tunnels/default.nix` plus the reduced
  `lib/services/tunnels/cloudflare.nix` provider wrapper from Abird's generic
  tunnel model.
- `lib/services/activesync/default.nix` timeout defaults from Abird's bounded
  silent HTTP wait fixes.

Repo-local adaptations:

- `hosts/pvl-x2/services/{docmost,memos,vaultwarden}/default.nix` now express
  Cloudflare publications as `tunnels = [{ kind = "cloudflare"; ... }]`.
- `hosts/pvl-x2/cloudflare.nix` and `hosts/pvl-vlab/cloudflare.nix` now import
  the provider-neutral tunnel helper and read
  `config.services.podman-compose.pvl.tunnelIngress.cloudflare`.
- `.agents/docs/notes/nixbot/deploy-system.md` documents the local cleanup and
  remote lock cleanup actions because Abird's matching wording lives in a
  consolidated note that this repo does not have.
- `.agents/docs/notes/services/edge-and-platform-infra.md` now names
  provider-neutral `tunnels` metadata instead of the removed `cfTunnelNames` /
  `cfTunnelPort` options.

Skipped as Abird-specific:

- Abird host inventories, `lib/stacks/abird*`, `lib/stacks/gap3.nix`, and scoped
  Abird secret payload rotations.
- Abird app/service packages under `pkgs/bots`, `pkgs/srv`, `pkgs/labs`,
  `pkgs/web`, and `pkgs/ext/gcp-cloud-run`.
- `pkgs/manifest.nix` changes outside the last-50 portable package scope; this
  repo already registers the adopted package families.
