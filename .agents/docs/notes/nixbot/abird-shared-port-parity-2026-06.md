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
