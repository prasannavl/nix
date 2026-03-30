# Podman Compose Services

This document describes the current Podman compose model in this repo, the
shared module, and the operational rules for creating, rebuilding, and debugging
compose-managed services.

## Why This Module Exists

Running container workloads with Podman compose on NixOS is straightforward in
isolation, but scaling it across hosts introduces repetitive plumbing:

- Every compose stack needs its YAML staged into a working directory, a systemd
  user service to run `podman compose up/down`, and restart logic when the
  definition changes.
- Secrets must be injected as file-backed environment variables without baking
  them into images.
- Firewall ports, nginx reverse-proxy entries, and Cloudflare Tunnel ingress
  rules must stay in sync with the ports each stack actually exposes.
- Deploy-time behavior must distinguish between active and inactive stacks so
  that a config change restarts running services without waking up intentionally
  stopped ones.

Without a shared module, each host would duplicate all of that wiring
independently and the definitions would drift. `lib/podman-compose/default.nix`
exists to own that lifecycle once so hosts only declare what is specific to
them: which stacks to run, what images to use, and which secrets to inject. The
module then generates the systemd units, firewall rules, and ingress metadata
automatically.

## Current Model

- `lib/podman.nix` owns shared Podman enablement and `containers.conf` defaults.
- `lib/podman-compose/default.nix` owns declarative compose lifecycle and passes
  per-instance metadata to `lib/podman-compose/helper.sh`, which owns the
  runtime shell flow:
  - working-directory staging
  - generated systemd user units
  - restart behavior on config changes
  - env-secret injection
  - firewall derivation from exposed ports
  - nginx and Cloudflare Tunnel metadata derivation
  - lifecycle tags
- `lib/systemd-user-manager/default.nix` owns deploy-time old-stop/new-start
  behavior for selected systemd user units.
- Host-specific stack declarations live under `hosts/<host>/services.nix`.
- Deploy targeting lives in `hosts/nixbot.nix`.

## Shared Module Model

Hosts declare compose stacks under:

```nix
services.podmanCompose.<stack> = {
  user = "app";
  stackDir = "/var/lib/app/compose";
  servicePrefix = "app-";

  instances.<name> = {
    bootTag = "0";
    recreateTag = "0";
    imageTag = "0";

    source = ''
      services:
        ${name}:
          image: docker.io/library/nginx:latest
          restart: unless-stopped
    '';
  };
};
```

When `services.podmanCompose` is non-empty, the shared module also:

- enables Podman
- enables `dockerCompat`
- enables DNS on the default Podman network
- installs both `podman` and `podman-compose`

## Declaration Patterns

The module supports a few different ways to declare compose content.

### 1. Render YAML from a Nix attrset

This is useful when you want Nix expressions to build the compose structure
directly:

```nix
services.podmanCompose.pvl.instances.dockge = {
  source = {
    services.dockge = {
      image = "louislam/dockge:1";
      restart = "unless-stopped";
      environment.DOCKGE_STACKS_DIR = "/var/lib/pvl/compose";
    };
  };
};
```

This is the pattern used by `dockge` on `pvl-x2`.

### 2. Inline YAML text in `source`

This is the simplest pattern for small services and generated definitions:

```nix
services.podmanCompose.gap3 = {
  user = "gap3";
  stackDir = "/var/lib/gap3/compose";

  instances.open-webui = {
    source = ''
      services:
        open-webui:
          image: ghcr.io/open-webui/open-webui:main
          restart: unless-stopped
          ports:
            - "0.0.0.0:13000:8080"
    '';
  };
};
```

This is the pattern used in `hosts/pvl-vlab/services.nix`.

### 3. Point `source` at a compose file in the repo

This is the right pattern when the main compose YAML already lives as a normal
file:

```nix
services.podmanCompose.pvl.instances.beszel = {podmanSocket, ...}: {
  source = ./compose/beszel/docker-compose.yml;

  files.".env" = ''
    PODMAN_SOCKET=${podmanSocket}
  '';
};
```

This is the most common pattern on `pvl-x2`.

### 4. Stage an entire compose directory with `files`

This is useful when a service is naturally a directory tree with multiple
compose fragments, env files, or companion config files:

```nix
services.podmanCompose.pvl.instances.opencloud = {
  entryFile = [
    "docker-compose.yml"
    "weboffice/collabora.yml"
    "external-proxy/opencloud.yml"
    "external-proxy/collabora.yml"
    "search/tika.yml"
  ];

  files = {
    "" = ./compose/opencloud2;
  };
};
```

In this pattern:

- `files."" = ./compose/opencloud2;` stages the whole directory tree into the
  working directory
- `entryFile` tells the module which staged compose files to pass to
  `podman compose -f ...`

### 5. Override or add files inline with `files`

You can also keep the main compose file as a repo path and override companion
files inline:

```nix
services.podmanCompose.pvl.instances.immich = {
  source = ./compose/immich/docker-compose.yml;

  files = {
    ".env" = ''
      IMMICH_HTTP_PORT=2283
      DB_USERNAME=postgres
      DB_DATABASE_NAME=immich
    '';
    "hwaccel.ml.yml" = ./compose/immich/hwaccel.ml.yml;
  };
};
```

This is the usual pattern when the base compose file should stay file-backed but
host-specific overlays, env files, or extra fragments should be generated in
Nix.

### When to use which

- Use an attrset `source` when Nix should generate the compose structure.
- Use inline text when the service is short and host-specific.
- Use a file-backed `source` when the main compose YAML should stay as a normal
  file in the repo.
- Use directory-backed `files` when the service is really a compose tree, not a
  single file.
- Use inline `files` overrides when the base compose file is stable but host
  overlays should still be generated declaratively.

## Generated Runtime Model

For each compose instance, the module generates a systemd user service that:

- stages rendered compose files into the working directory
- removes manifest-managed file-versus-directory conflicts before restaging, so
  bind-mounted runtime paths can safely change shape across deploys
- runs `podman compose up -d --remove-orphans`
- verifies that compose did not leave any container stuck in `Created` or
  another non-running state
- only reports systemd startup success after that verification passes
- stays attached with a provider-agnostic monitor loop so systemd can observe
  runtime failure even when the external compose provider does not implement
  `wait`
- runs `podman compose down` on stop
- restages files and re-runs `up -d` on reload

The main generated service is intentionally stateless:

- no lifecycle tag state is stored on disk
- boot-time startup is gated behind `systemd-user-manager-ready.target`, so the
  main compose services do not start until the per-user reconciler has run once

## Tags

- `bootTag`:
  - default is `"0"`
  - when the declared value changes, the main generated compose unit is treated
    as changed
  - active stacks restart through the normal managed-unit path
- `recreateTag`:
  - default is `"0"`
  - when the declared value changes, the main generated compose unit is treated
    as changed
  - it does not change steady-state `ExecStart` behavior
  - instead it forces the normal managed stop/start switch path for active
    stacks
- `imageTag`:
  - default is `"0"`
  - generates a separate oneshot image-pull user unit
  - the main compose unit starts after that pull unit when image refresh is
    enabled
  - changing `imageTag` alone does not restart the main compose unit

Operationally, the intended manual toggles are between `"0"` and `"1"`, though
any new string value works.

## What Changes Trigger

- `bootTag` change:
  - changes the main generated user unit restart stamp
  - only the declared `bootTag` value participates in that tag-specific stamp
  - active stacks restart through the normal managed-unit path
- `recreateTag` change:
  - changes the main generated user unit restart stamp
  - causes a managed stop/start cycle for active stacks during deploy
  - does not remain sticky after that generation switch
- `imageTag` change:
  - changes the separate generated image-pull user unit
  - does not by itself restart the main compose unit
  - any future start or restart of the main compose unit runs the pull unit
    first
- compose `source`, `files`, `entryFile`, `envSecrets`, or generated unit
  change:
  - changes the main generated user service and restart stamp
  - active stacks restart on deploy
  - inactive stacks are started during reconcile unless disabled or masked
- plain reboot:
  - starts the main compose user service
  - runs the image-pull helper first when image refresh is enabled
  - does not replay `recreateTag`

## Restart Trigger Coverage

- `source` content is covered. When the compose source changes, the rendered
  store path changes, and that path is part of the main restart stamp.
- `files` content is covered for the same reason. Rendered or copied store paths
  for staged files participate in the restart stamp.
- `entryFile` selection is covered because it changes the generated user unit.
- Generated unit configuration is covered. Changes to service environment,
  dependencies, or other generated unit wiring change the restart stamp through
  the rendered systemd unit.
- `envSecrets` mapping structure is covered. Adding, removing, or changing
  `envSecrets.<composeService>.<ENV_VAR> = /path/to/secret` changes the restart
  stamp.
- `envSecrets` decrypted content at the same configured path is not covered. If
  the secret payload changes but the configured path stays the same, the restart
  stamp does not change, so reconcile may legitimately noop.

## Derived Metadata

`services.podmanCompose.<stack>.instances.<name>.exposedPorts` is the source of
truth for compose-managed port metadata.

It drives:

- host firewall openings when `openFirewall = true`
- derived nginx reverse-proxy metadata
- derived Cloudflare Tunnel ingress metadata

## Secrets

The supported secret model is file-backed `envSecrets`:

```nix
envSecrets.<composeService>.<ENV_VAR> = /path/to/secret;
```

The module generates an override file that adds `env_file` wiring, so secrets
can be injected without replacing the image entrypoint or command.

Secret rotation caveat:

- `envSecrets` files are restaged on `start`, `reload`, and `image-pull`
- rotating a secret's contents at the same path does not by itself force a
  restart or restage
- if you need deploy-time reconcile to pick that up, bump `bootTag`
- bump `recreateTag` only if you also want the next start to use
  `podman compose up --force-recreate`

## Deployment And Sequencing

On host deploy:

1. systemd reloads the affected user manager once
2. changed bridge units stop
3. changed bridge units start in the new generation
4. the reconciler starts inactive managed units in the new generation

That means:

- Podman stacks must never make boot activation fail; boot-time ordering is
  handled after activation through `systemd-user-manager`'s normal boot unit and
  `systemd-user-manager-ready.target`
- boot-time service startup waits for `systemd-user-manager-ready.target`, which
  the reconciler starts after a successful per-user apply
- `dry-activate` logs the starts it would perform, but does not actually mutate
  the running user services
- `imageTag` is implemented as a normal helper unit, not a reconciler action
- `bootTag` and `recreateTag` are expressed as changes to the main unit itself

## What A Host Must Provide

For each stack in `hosts/<host>/services.nix`:

- `user`
- `stackDir`
- one or more `instances`
- either `source` or `files` for each instance
- optional `bootTag`
- optional `recreateTag`
- optional `imageTag`
- optional `dependsOn`, `wants`, `envSecrets`, `exposedPorts`,
  `serviceOverrides`

## How To Create A New Compose Service

1. Add or update `hosts/<host>/services.nix`.
2. Declare a stack under `services.podmanCompose.<stack>`.
3. Add one or more instances.
4. If the service needs ingress, define `exposedPorts`.
5. If it needs secrets, define `envSecrets`.
6. Deploy the host.

## FAQ

### What happens when I change compose source?

The main generated user unit changes. If the stack was active, the deploy-time
bridge restarts it. If it was inactive but still startable, reconcile starts it.

### What happens when I bump `recreateTag`?

The main generated unit changes, so active stacks restart through the normal
managed-unit path. `recreateTag` is now a switch-time trigger only: it changes
the managed-unit stamp so the active stack is stopped and started in the new
generation, but it does not stay encoded in steady-state `ExecStart` behavior.

### What happens when I bump `bootTag`?

The managed unit stamp changes. If the stack was active, the normal
systemd-user-manager reconciliation path restarts the main compose unit. This is
keyed to the declared `bootTag` value itself, not helper script path or other
generated unit churn.

### What happens when I bump `imageTag`?

The separate image-pull unit changes. That does not by itself restart the main
compose service. The next time the main service starts or restarts, systemd runs
the image-pull unit first.

### Why didn't an `envSecrets` secret rotation restart my service?

Because the restart stamp tracks the configured `envSecrets` mapping and target
paths, not the decrypted contents of a secret file when that file remains at the
same path. If the payload rotates at the same path, bump `bootTag` to force the
normal reconcile restart path.

### Does boot gating behind `systemd-user-manager-ready.target` create a deadlock?

No. That target only gates automatic boot startup. The reconciler still talks to
the Podman unit directly with `systemctl --user start` or `restart` during
apply, then starts `systemd-user-manager-ready.target` after a successful run.

### What does `dry-activate` show for Podman stacks?

It runs the `systemd-user-manager` preview path. That means you get log lines
for the managed unit starts it would perform, but no actual compose action is
run.

### If a stack is intentionally inactive, do tag bumps wake it up?

Yes. The simplified model treats the generated main unit as desired state. If it
is managed and startable, reconcile starts it.

### Does `imageTag` rebuild build-only services?

Not by itself. `imageTag` uses `podman compose pull`, so build-only services may
need an explicit build flow if image refresh semantics need to cover them too.

## Related Docs

- `docs/services.md`: Native service pattern for non-container workloads.
- `docs/systemd-user-manager.md`: Deploy-time user-service bridge module used by
  `lib/podman-compose/default.nix`.
- `docs/incus-vms.md`: Incus guest lifecycle (uses the same lifecycle tag
  conventions).
- `docs/deployment.md`: Deploy architecture and secret model.

## Source Of Truth Files

- `lib/podman.nix`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
- `lib/systemd-user-manager/default.nix`
- `hosts/<host>/services.nix`
- `hosts/nixbot.nix`
