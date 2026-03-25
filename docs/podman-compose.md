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
independently and the definitions would drift. `lib/podman.nix` exists to own
that lifecycle once so hosts only declare what is specific to them: which stacks
to run, what images to use, and which secrets to inject. The module then
generates the systemd units, firewall rules, and ingress metadata automatically.

## Current Model

- `lib/podman.nix` owns declarative compose lifecycle:
  - working-directory staging
  - generated systemd user units
  - restart behavior on config changes
  - env-secret injection
  - firewall derivation from exposed ports
  - nginx and Cloudflare Tunnel metadata derivation
  - lifecycle tags
- `lib/systemd-user-manager.nix` owns deploy-time old-stop/new-start behavior
  for selected systemd user units.
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

This is the pattern used in `hosts/gap3-rivendell/services.nix`.

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
- runs `podman compose up -d --remove-orphans`
- runs `podman compose down` on stop
- restages files and re-runs `up -d` on reload

The main generated service is intentionally stateless:

- no lifecycle tag state is stored on disk
- no lifecycle tag action is replayed just because the machine rebooted

## Tags

- `bootTag`:
  - default is `"0"`
  - when the declared value changes, deploy-time bridge logic runs
    `podman compose restart`
- `recreateTag`:
  - default is `"0"`
  - when the declared value changes, deploy-time bridge logic runs
    `podman compose up --force-recreate`
- `imageTag`:
  - default is `"0"`
  - when the declared value changes, deploy-time bridge logic runs
    `podman compose pull`

Operationally, the intended manual toggles are between `"0"` and `"1"`, though
any new string value works.

## What Changes Trigger

- `bootTag` change:
  - runs the generated `*-boot-tag.service`
  - attempts `podman compose restart`
  - falls back to `up -d --remove-orphans` if the stack does not exist yet
- `recreateTag` change:
  - runs the generated `*-recreate-tag.service`
  - uses `podman compose up --force-recreate`
- `imageTag` change:
  - runs the generated `*-image-tag.service`
  - uses `podman compose pull`
- compose `source`, `files`, `entryFile`, `envSecrets`, or generated unit
  change:
  - changes the main generated user service and restart stamp
  - active stacks restart on deploy
  - inactive stacks stay inactive
- plain reboot:
  - starts the main compose user service only
  - does not replay lifecycle tags

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

## Deployment And Sequencing

On host deploy:

1. systemd reloads the affected user manager once
2. changed bridge units stop
3. changed bridge units start in the new generation
4. active stacks either restart normally or run lifecycle tag actions, depending
   on what changed

That means:

- lifecycle tags are deploy-time actions, not boot-time actions
- if the same deploy changes both `imageTag` and `recreateTag`, both generated
  action units fire for the active stack

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
bridge restarts it. If it was inactive, it stays inactive.

### What happens when I bump `recreateTag`?

The deploy-time bridge starts the generated `*-recreate-tag.service`, which runs
`podman compose up --force-recreate`.

### What happens when I bump `bootTag`?

The deploy-time bridge starts the generated `*-boot-tag.service`, which runs
`podman compose restart`.

### What happens when I bump `imageTag`?

The deploy-time bridge starts the generated `*-image-tag.service`, which runs
`podman compose pull`.

### Do lifecycle tags replay on reboot?

No. Lifecycle tags are stateless deploy-time actions. Reboot only starts the
main compose service.

### If a stack is intentionally inactive, do tag bumps wake it up?

No. Lifecycle tag actions only fire for stacks whose main user unit was active
in the previous generation.

### Do new non-default tags fire immediately the first time the tag unit exists?

No. A newly introduced non-default tag does not retroactively fire just because
the tag bridge appeared for the first time. It fires on subsequent tag changes.

### Does `imageTag` rebuild build-only services?

Not by itself. `imageTag` uses `podman compose pull`, so build-only services may
need an explicit build flow if image refresh semantics need to cover them too.

## Related Docs

- `docs/services.md`: Native service pattern for non-container workloads.
- `docs/systemd-user-manager.md`: Deploy-time user-service bridge module used by
  `lib/podman.nix`.
- `docs/incus-vms.md`: Incus guest lifecycle (uses the same lifecycle tag
  conventions).
- `docs/deployment.md`: Deploy architecture and secret model.

## Source Of Truth Files

- `lib/podman.nix`
- `lib/systemd-user-manager.nix`
- `hosts/<host>/services.nix`
- `hosts/nixbot.nix`
