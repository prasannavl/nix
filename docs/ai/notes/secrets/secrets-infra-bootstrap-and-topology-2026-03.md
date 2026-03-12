# Secrets Infra Bootstrap And Topology (2026-03)

## Scope

Documents the repo's current secret topology from four angles:

- each machine's age identity
- bastion ingress and downstream deploy identity
- service secret delivery
- clean-room bootstrap order

## Canonical code paths

- `data/secrets/default.nix`
- `hosts/nixbot.nix`
- `lib/nixbot/default.nix`
- `lib/nixbot/bastion.nix`
- `hosts/<bastion-host>/services.nix`
- `lib/incus-machine.nix`
- `scripts/nixbot-deploy.sh`
- `docs/deployment.md`

## Durable model

- Host activation decrypt does not use the deploy SSH key.
- Each host has a machine-scoped age identity injected to
  `/var/lib/nixbot/.age/identity` before activation.
- Bastion is the configured bastion host.
- `nixbot` is the shared deploy user on every managed node.
- Bastion has two separate SSH trust domains:
  - forced-command ingress key for CI/operator entry
  - downstream deploy key for SSH from bastion to managed hosts
- Service secrets are encrypted to the consuming machine recipient and are
  materialized through `age.secrets.*` on that machine.
- The public-key trust exchange is mostly declarative:
  - `lib/nixbot/default.nix` installs `nixbot.sshKeys` on all nodes
  - `lib/nixbot/bastion.nix` installs `nixbot.bastionSshKeys` on bastion with a
    forced command
- The private-key handoff is partly runtime:
  - bastion receives the shared deploy private key from
    `data/secrets/nixbot/nixbot.key.age`
  - bootstrap can copy that same key to a fresh target's
    `/var/lib/nixbot/.ssh/id_ed25519`
  - deploy always copies the machine age identity to
    `/var/lib/nixbot/.age/identity` before activation

## What bootstrap means here

- Bootstrap means using a pre-existing admin path to get a host onto the normal
  `nixbot` deploy model.
- A host is not fully bootstrapped yet if normal `nixbot@host` access,
  `/var/lib/nixbot/.ssh/id_ed25519`, or `/var/lib/nixbot/.age/identity` is
  still missing.
- Bastion must be bootstrapped first because it is the trust anchor for the
  later CI/operator -> bastion -> fleet path.
- `hosts/nixbot.nix` expresses the bootstrap path through:
  - `bootstrapUser`
  - `bootstrapKeyPath`
  - `bootstrapKey`
- `scripts/nixbot-deploy.sh` uses that path to:
  - fall back to an existing admin account
  - install the shared `nixbot` deploy key when needed
  - install the machine age identity before activation

## Why bootstrap is necessary

- The steady-state model assumes `nixbot` already works.
- The first deploy to a machine is exactly the time when that assumption may be
  false.
- Bootstrap is the bridge that resolves that chicken-and-egg problem.

## Current topology

- Machine identities:
  - `<desktop-host>` -> `data/secrets/machine/<desktop-host>.key.age`
  - `<bastion-host>` -> `data/secrets/machine/<bastion-host>.key.age`
  - `<incus-guest>` -> `data/secrets/machine/<incus-guest>.key.age`
- Shared deploy user:
  - user: `nixbot`
  - default target mapping: `hosts/nixbot.nix`
  - target-host SSH trust is loaded from `users/userdata.nix` via
    `lib/nixbot/default.nix`
- Bastion ingress private key:
  - `data/secrets/bastion/nixbot-bastion-ssh.key.age`
  - recipients: admins only
- Bastion downstream deploy private key:
  - `data/secrets/nixbot/nixbot.key.age`
  - recipients: admins + active `nixbot` deploy keys + the bastion machine
    recipient
- Optional bastion overlap key:
  - `data/secrets/nixbot/nixbot-legacy.key.age`
- Service secrets:
  - `data/secrets/services/*` for bastion-host services and bastion Cloudflare
    TF
  - `data/secrets/tailscale/<host>.key.age` for guest Tailscale auth

## Bootstrap order

1. Define admin and `nixbot` public keys in `users/userdata.nix`.
2. Generate and encrypt the bastion ingress private key.
3. Generate and encrypt the shared `nixbot` deploy private key.
4. Generate and encrypt one machine age identity per host.
5. Commit each machine public recipient in `data/secrets/machine/*.key.pub`.
6. Update `data/secrets/default.nix` so every managed secret has the intended
   recipients.
7. Encrypt secrets and clean plaintext siblings with `scripts/age-secrets.sh`.
8. Bootstrap the bastion host first.
9. Use bastion-driven deploys to inject host age identities onto the remaining
   hosts before activation.
10. Add service secrets only after the target machine identity path works.

## Where key exchange happens

- Declarative public-key exchange:
  - `users/userdata.nix` stores the public keys
  - `lib/nixbot/default.nix` installs deploy public keys on all nodes
  - `lib/nixbot/bastion.nix` installs forced-command ingress public keys on
    bastion
- Bootstrap path selection:
  - `scripts/nixbot-deploy.sh` first tries steady-state `nixbot@host`
  - if that fails, it may validate forced-command bootstrap reachability with
    `check_bootstrap_via_forced_command()`
  - if that is still not enough, it falls back to `${bootstrapUser}@host`
- Runtime deploy-key exchange:
  - `scripts/nixbot-deploy.sh` `inject_bootstrap_nixbot_key()` copies the
    shared `nixbot` private key to `/var/lib/nixbot/.ssh/id_ed25519` on the
    target when bootstrap is needed
- Runtime machine-identity exchange:
  - `scripts/nixbot-deploy.sh` `inject_host_age_identity_key()` copies the
    host-specific age identity to `/var/lib/nixbot/.age/identity` before
    activation

## Important operator rule

- For a brand-new host, the first real deploy should go through
  `scripts/nixbot-deploy.sh` or an equivalent manual copy of the machine age
  identity to `/var/lib/nixbot/.age/identity`. Otherwise agenix decrypt will
  fail during activation.
