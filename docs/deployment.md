# Deployment Decisions

This document describes the current `nixbot` deployment architecture and
security model.

## Current Model

- Bastion host: the configured bastion (`hosts/<bastion>/default.nix`, imports
  `lib/nixbot/bastion.nix`)
- Deploy orchestration script: `scripts/nixbot-deploy.sh`
- Deploy mapping/config: `hosts/nixbot.nix`
- Secrets storage: `data/secrets/*.age` (age/agenix)

## Key Roles

### 1) CI -> Bastion (`nixbot@<bastion>`)

- CI uses a dedicated bastion ingress key (`nixbot-bastion-ssh`).
- That key is forced-command-only on bastion:
  - command: `/var/lib/nixbot/nixbot-deploy.sh`
  - no shell / no forwarding flags.
- CI/local trigger does not SCP/upload deploy scripts to bastion at runtime. It
  must invoke the pre-installed forced-command script path above. This prevents
  turning deploy ingress into arbitrary remote code execution.
- Do not enable `--use-repo-script` / `DEPLOY_USE_REPO_SCRIPT=1` in CI by
  default. The security reason is that it would let the forced-command ingress
  path execute newly fetched repo script logic before bastion itself has been
  updated to that trusted version. CI should stay pinned to the installed
  bastion wrapper and use a two-phase rollout when deploy-script behavior
  changes:
  1. deploy bastion/script-wrapper changes first
  2. let later runs use the updated installed wrapper
- Source of key material:
  - `users/userdata.nix` (`nixbot.bastionSshKeys`, fallback
    `nixbot.bastionSshKey`)
  - wired by `lib/nixbot/bastion.nix`

### 2) Regular `nixbot` SSH Key

- `nixbot.sshKeys` are regular SSH keys for non-forced-command access.
- The singular `nixbot.sshKey` is retained as a backward-compatible alias.
- It is defined by the base nixbot user module (`lib/nixbot/default.nix`).
- Bastion module does not override/remove it.

### 2a) What `nixbot` Is And How It Deploys

- `nixbot` is the dedicated system user used for NixOS deploy orchestration on
  every managed host.
- `lib/nixbot/default.nix` creates the `nixbot` user/group, gives it
  passwordless sudo, and marks it as a trusted Nix user.
- `hosts/nixbot.nix` declares that `nixbot` is the default deploy user for all
  managed nodes:
  - `defaults.user = "nixbot"`
  - `defaults.key = "data/secrets/nixbot/nixbot.key.age"`
- The normal steady-state deploy path is:
  1. CI/operator reaches bastion as `nixbot@<bastion>` via the forced-command
     ingress key.
  2. Bastion runs `/var/lib/nixbot/nixbot-deploy.sh`.
  3. That script uses the bastion's local `nixbot` private key at
     `/var/lib/nixbot/.ssh/id_ed25519` to SSH to `nixbot@<target>`.
  4. `nixos-rebuild --target-host` then switches the target, using `nixbot`'s
     sudo privileges on that host.
- Bastion can access other nodes through `nixbot` because those nodes trust the
  public keys listed in `users/userdata.nix` under `nixbot.sshKeys`, which are
  installed as `users.users.nixbot.openssh.authorizedKeys.keys` by
  `lib/nixbot/default.nix`.
- In short:
  - ingress to bastion uses `nixbot.bastionSshKeys`
  - bastion to other hosts uses `nixbot.sshKeys`
  - activation-time secret decrypt uses the machine age identity, not either
    SSH key class

### 3) Bastion Runtime Private Key + Secrets

- Bastion stores deploy private key at:
  - `/var/lib/nixbot/.ssh/id_ed25519`
- During overlap rotation, bastion may also retain legacy deploy key at:
  - `/var/lib/nixbot/.ssh/id_ed25519_legacy`
- Installed from:
  - `data/secrets/nixbot/nixbot.key.age`
- Legacy optional install source:
  - `data/secrets/nixbot/nixbot-legacy.key.age`

### 4) Machine Runtime Age Identity (Activation-Time Decrypt)

- Each host has a machine-scoped age private key installed at:
  - `/var/lib/nixbot/.age/identity`
- Hosts use this path in:
  - `age.identityPaths = [ "/var/lib/nixbot/.age/identity" ]`
- `scripts/nixbot-deploy.sh` injects that key pre-activation from per-host
  encrypted files:
  - `data/secrets/machine/<host>.key.age`
- This avoids identity bootstrap loops (identity is no longer under
  `/run/agenix` outputs).

## Bastion Wiring Requirements

In `lib/nixbot/bastion.nix`:

- Add forced-command authorized key entry for `bastionSshKey`.
- Install current script to stable path:
  - `install -m 0755 ${../../scripts/nixbot-deploy.sh} /var/lib/nixbot/nixbot-deploy.sh`
- Ensure runtime prerequisites:
  - `/var/lib/nixbot/.ssh` exists, mode `0700`, owner `nixbot`
  - `environment.systemPackages` includes `age` and `jq`
- Ensure nixbot SSH client identity order includes both current and legacy key
  paths during rotation.

## Bootstrap Strategy

In this repo, "bootstrap" means using an already-available admin path to get a
host to the point where the normal `nixbot` deploy path works.

Concretely, bootstrap is needed when a node does not yet satisfy one or more of
these steady-state assumptions:

- `nixbot@host` is not reachable with the shared deploy key
- `/var/lib/nixbot/.ssh/id_ed25519` is not installed on the target
- `/var/lib/nixbot/.age/identity` is not installed on the target
- the host has not yet been switched onto the repo's `nixbot`/agenix model

Bootstrap matters especially for bastion because the bastion host is the first trust
anchor for the whole fleet:

- CI and remote operators enter through bastion first, not directly to every
  node
- bastion is where the shared `nixbot` deploy private key is decrypted to
  `/var/lib/nixbot/.ssh/id_ed25519`
- bastion is the host that later SSHes to the rest of the fleet as `nixbot`
- bastion also holds the OpenTofu/Cloudflare runtime secrets used by
  `--action tf`

Until bastion itself is bootstrapped, the normal CI -> bastion -> node deploy
chain does not exist yet.

`hosts/nixbot.nix` supports bootstrap fallback fields:

- `bootstrapKey` (defaults + optional per-host override)
- `bootstrapUser`
- `bootstrapKeyPath`

Those fields describe the non-steady-state access path used to get a host onto
the normal `nixbot` path:

- `bootstrapUser`: the account that already exists on the target and can sudo
- `bootstrapKeyPath`: optional direct SSH key path for reaching that bootstrap
  account
- `bootstrapKey`: the private key material that should be installed as
  `/var/lib/nixbot/.ssh/id_ed25519` on the target once bootstrap succeeds

During deploy, script behavior is:

1. Build host system closure.
2. Attempt primary target (`nixbot@host`) shell reachability.
3. If primary shell access fails, run forced-command bootstrap check
   (`--action check-bootstrap`) via bastion key.
4. If bootstrap check still fails, inject bootstrap key using bootstrap user
   path.
5. Continue deployment (currently via `nixos-rebuild --target-host`).
6. `--bootstrap` skips step 2 probing and forces bootstrap target selection for
   deploy/snapshot/rollback operations.

Important: successful forced-command bootstrap check does not imply general
shell access for `nixos-rebuild --target-host`.

### What "bootstrap check" means

- `--action check-bootstrap` does not deploy anything.
- It validates whether the configured bootstrap material can be resolved and, in
  the forced-command case, whether the remote bastion-side wrapper can accept
  the request.
- In the current flow this is mainly used when the primary path is
  forced-command-only or otherwise not a normal shell session.

### What "bootstrap fallback" means

- Bootstrap fallback means the deploy script stops trying to use `nixbot@host`
  as the transport for the current step and temporarily uses
  `${bootstrapUser}@host` instead.
- Over that fallback path it can:
  - install the shared `nixbot` deploy private key to
    `/var/lib/nixbot/.ssh/id_ed25519`
  - install the machine age identity to `/var/lib/nixbot/.age/identity`
  - run `nixos-rebuild --target-host` using the bootstrap account's sudo path
- After the host has been switched successfully, later runs are expected to use
  normal `nixbot@host` access instead of bootstrap.

### Why bootstrap is necessary at all

- A brand-new or partially configured host cannot decrypt agenix secrets until
  it has its machine age identity.
- A host also cannot participate in the normal bastion-to-node deploy path
  until it trusts `nixbot` and has the expected SSH material in place.
- Bootstrap breaks that chicken-and-egg problem by using some pre-existing
  admin path just long enough to install the `nixbot` and age identity state
  that the steady-state model requires.

## Key Exchange And Trust Installation

### Static key exchange from configuration

- `users/userdata.nix` is the source of truth for the public SSH keys trusted by
  the `nixbot` user.
- `lib/nixbot/default.nix` installs `nixbot.sshKeys` onto every managed host as
  `nixbot` authorized keys.
- `lib/nixbot/bastion.nix` separately installs `nixbot.bastionSshKeys` onto the
  bastion's `nixbot` account, but wrapped in a forced command:
  - only `/var/lib/nixbot/nixbot-deploy.sh` may run
  - no shell, PTY, forwarding, or user rc files
- This means there are two SSH trust exchanges:
  - all managed nodes learn the normal deploy public keys at activation time
  - the bastion learns the restricted ingress public keys at activation time

### Runtime key exchange during bootstrap

- The private side of the shared deploy key lives encrypted at
  `data/secrets/nixbot/nixbot.key.age`.
- On bastion, `lib/nixbot/bastion.nix` decrypts that file to:
  - `/var/lib/nixbot/.ssh/id_ed25519`
- During bootstrap of another node, `scripts/nixbot-deploy.sh` may also copy
  that same private key onto the target if `nixbot@target` is not usable yet.
- The exchange happens in `inject_bootstrap_nixbot_key()`:
  - the key is decrypted locally by the deploy script from the configured
    `bootstrapKey`
  - copied to a temporary remote file over the bootstrap account
  - installed remotely as `/var/lib/nixbot/.ssh/id_ed25519`
  - any previous key is preserved as `/var/lib/nixbot/.ssh/id_ed25519_legacy`
- This is the key handoff that lets a fresh node start accepting
  `nixbot@host` deploy connections on later runs.

### Runtime machine-identity exchange during activation

- Machine age identities are not kept in the image or bootstrap account by
  default.
- Instead, `scripts/nixbot-deploy.sh` injects them just before activation in
  `inject_host_age_identity_key()`.
- The exchange happens as:
  1. decrypt configured `hosts.<node>.ageIdentityKey`
  2. copy it over SSH to a temporary remote file
  3. install it as `/var/lib/nixbot/.age/identity`
  4. run activation, where agenix uses that path to decrypt host secrets
- This is why first deploys must go through the deploy script or an equivalent
  manual copy step.

## End-to-End Secret Flow

1. CI/operator reaches bastion using forced-command ingress key
   (`nixbot-bastion-ssh`).
2. Bastion uses `nixbot` deploy key (`/var/lib/nixbot/.ssh/id_ed25519`) to SSH
   to target hosts and to decrypt repo-side `nixbot`-recipient `.age` files used
   by deploy tooling.
3. Before each target activation, `scripts/nixbot-deploy.sh` injects
   host-specific machine age private key to:
   - `/var/lib/nixbot/.age/identity`
4. Target activation runs agenix with:
   - `age.identityPaths = [ "/var/lib/nixbot/.age/identity" ]`
5. Secrets are materialized on target and access to plaintext is constrained
   with Unix ownership/mode via `age.secrets.<name>.owner/group/mode`.

## Secret Topology By Scope

### Machine identities

- `<desktop-host>`
  - deploy metadata: `hosts/nixbot.nix` ->
    `hosts.<desktop-host>.ageIdentityKey = "data/secrets/machine/<desktop-host>.key.age"`
  - recipients: admins + current `nixbot` deploy keys
  - runtime path on host: `/var/lib/nixbot/.age/identity`
- `<bastion-host>`
  - deploy metadata: `hosts/nixbot.nix` ->
    `hosts.<bastion-host>.ageIdentityKey = "data/secrets/machine/<bastion-host>.key.age"`
  - recipients: admins + current `nixbot` deploy keys
  - runtime path on host: `/var/lib/nixbot/.age/identity`
  - this host is also the bastion, so its machine recipient is included on the
    shared bastion deploy-key secret and the bastion Cloudflare/OpenTofu
    runtime secrets
- `<incus-guest>`
  - deploy metadata: `hosts/nixbot.nix` ->
    `hosts.<incus-guest>.ageIdentityKey = "data/secrets/machine/<incus-guest>.key.age"`
  - recipients: admins + current `nixbot` deploy keys
  - runtime path on host: `/var/lib/nixbot/.age/identity`
  - host also consumes `data/secrets/tailscale/<incus-guest>.key.age`
    directly through `lib/incus-machine.nix`

### Bastion identities and secrets

- Bastion host is the configured bastion target.
- Bastion ingress identity is the SSH key whose public half is loaded from
  `users/userdata.nix` (`nixbot.bastionSshKeys` / `nixbot.bastionSshKey`) and
  forced into `/var/lib/nixbot/nixbot-deploy.sh` by `lib/nixbot/bastion.nix`.
- The private half of that ingress key is stored as
  `data/secrets/bastion/nixbot-bastion-ssh.key.age`.
  - recipients: admins only
  - consumers: CI or an operator initiating a bastion-triggered deploy
- Bastion's downstream deploy identity is the private key in
  `data/secrets/nixbot/nixbot.key.age`.
  - recipients: admins + current `nixbot` deploy keys + the bastion machine age
    recipient
  - runtime path on bastion: `/var/lib/nixbot/.ssh/id_ed25519`
  - trusted by other nodes because `lib/nixbot/default.nix` installs the
    corresponding public keys into the `nixbot` account on those nodes
- Optional overlap key:
  - source: `data/secrets/nixbot/nixbot-legacy.key.age`
  - runtime path: `/var/lib/nixbot/.ssh/id_ed25519_legacy`
  - purpose: keep bastion able to reach nodes that still trust the old deploy
    public key during rotation

### Service secrets

- General pattern:
  1. recipient set is declared in `data/secrets/default.nix`
  2. the consumer host exposes the secret through `age.secrets.*`
  3. the consuming service reads the materialized file path, not repo plaintext
- Bastion-host compose services:
  - source files live under `data/secrets/services/<service>/*.key.age`
  - recipients are admins + the bastion machine age recipient
  - `hosts/<bastion-host>/services.nix` maps them into `age.secrets.*`
  - `services.podmanCompose.*.envSecrets` injects them into containers as
    file-backed environment values
- Bastion OpenTofu/Cloudflare runtime:
  - source files live under `data/secrets/cloudflare/*.key.age`
  - recipients are admins + the bastion host
  - `lib/nixbot/bastion.nix` decrypts them to
    `/var/lib/nixbot/secrets/cloudflare-tf/*`
  - `scripts/nixbot-deploy.sh --action tf` auto-loads them into the OpenTofu
    environment when shell variables are absent
- Incus-guest Tailscale auth:
  - source file:
    `data/secrets/tailscale/<incus-guest>.key.age`
  - recipients: admins + `<incus-guest>`
  - `lib/incus-machine.nix` exposes it as
    `services.tailscale.authKeyFile`

### Incus guest secret notes

- Incus guests do not currently have a separate Incus-specific secret system.
- They use the same host secret model as any other managed node:
  - machine age identity in `data/secrets/machine/<host>.key.age`
  - optional service secrets encrypted to that guest's machine recipient
- The one shared guest-specific convenience path today is in
  `lib/incus-machine.nix`:
  - optional Tailscale auth secret at
    `data/secrets/tailscale/<host>.key.age`
  - wired to `services.tailscale.authKeyFile` only if the encrypted file exists
- Incus guest SSH host keys are persisted under `/var/lib/machine/*`, but those
  are runtime-generated host keys, not repo-managed agenix secrets.
- For an Incus guest, the related repo secrets are therefore:
  - `data/secrets/machine/<incus-guest>.key.age`
  - `data/secrets/tailscale/<incus-guest>.key.age`

## Adding A New Machine Or Secret

### New machine identity

1. Generate a new age identity for the host.
2. Commit the public recipient to
   `data/secrets/machine/<host>.key.pub`.
3. Encrypt the private identity to
   `data/secrets/machine/<host>.key.age`.
4. Add the new `.key.age` entry and its recipients in
   `data/secrets/default.nix`.
5. Point `hosts/nixbot.nix` at that secret with
   `hosts.<host>.ageIdentityKey`.
6. Re-encrypt managed secrets so any host-specific secrets now include the new
   machine recipient.

### New service secret

1. Create the secret file under `data/secrets/services/<service>/`.
2. Add the recipient policy in `data/secrets/default.nix`.
3. Wire it into the consuming host with `age.secrets.<name>.file = ...`.
4. Pass `config.age.secrets.<name>.path` to the service, usually through
   `envSecrets` or a `*File` setting.
5. Re-encrypt the managed secrets set.

## Kickstarting From Scratch

Use this order for a clean-room rebuild of the current model.

1. Establish the long-lived human/admin keys in `users/userdata.nix`.
   - These keys must be able to decrypt every machine identity, the bastion
     ingress key, and the bastion deploy key.
2. Generate the shared `nixbot` deploy SSH keypair.
   - public key goes into `users/userdata.nix` (`nixbot.sshKeys`)
   - private key becomes `data/secrets/nixbot/nixbot.key.age`
3. Generate the bastion ingress SSH keypair.
   - public key goes into `users/userdata.nix` (`nixbot.bastionSshKeys`)
   - private key becomes
     `data/secrets/bastion/nixbot-bastion-ssh.key.age`
4. Generate one machine age identity per host.
   - private identities become `data/secrets/machine/<host>.key.age`
   - public recipients become `data/secrets/machine/<host>.key.pub`
5. Fill in `data/secrets/default.nix`.
   - every managed `*.age` file must have the correct recipient set before
     encryption is trustworthy
6. Create plaintext secret payloads only long enough to encrypt them.
   - use `scripts/age-secrets.sh encrypt data/secrets`
   - then remove plaintext siblings with
     `scripts/age-secrets.sh clean data/secrets`
7. Bootstrap the bastion host first.
   - it is the bastion and the only host that can later decrypt the shared
     deploy key and Cloudflare/OpenTofu runtime secrets
   - initial access still depends on the configured bootstrap account in
     `hosts/nixbot.nix` (currently `defaults.bootstrapUser = "pvl"`)
   - once deployed, it becomes the place where `nixbot` holds the shared deploy
     private key and initiates downstream SSH to the rest of the fleet
   - this is the step that creates the CI/operator -> bastion -> fleet trust
     chain; before it, only the bootstrap/admin path exists
8. Validate bastion ingress after the bastion host is up.
   - the forced-command key should be able to run
     `/var/lib/nixbot/nixbot-deploy.sh`
   - the bastion should hold `/var/lib/nixbot/.ssh/id_ed25519`
9. Deploy the remaining hosts through `scripts/nixbot-deploy.sh`.
   - first managed deploy to each host injects
     `/var/lib/nixbot/.age/identity`
   - after that, agenix can decrypt host-local secrets during activation
10. Only after bastion and machine identities are working, add higher-level
    service secrets.
    - bastion-host service secrets can be activated once bastion decrypt works
    - Incus-guest Tailscale auth can be activated once that host's
      machine identity is wired and deployable

## Scratch Bootstrap Failure Modes

- If a host is activated out-of-band without first receiving
  `/var/lib/nixbot/.age/identity`, agenix-managed host secrets will not decrypt.
- If the bastion host is missing from the recipient list of
  `data/secrets/nixbot/nixbot.key.age`, bastion cannot obtain the downstream
  deploy private key.
- If a service secret omits the consuming machine recipient, activation will
  succeed but the secret file will never materialize on that host.
- If `data/secrets/default.nix` and the committed `*.pub` files diverge,
  `scripts/age-secrets.sh encrypt` may succeed for the wrong recipient set, so
  treat that file as the canonical policy review point.

## Deploy Config Defaults (`hosts/nixbot.nix`)

- `defaults.user = "nixbot"`
- `defaults.key = "data/secrets/nixbot/nixbot.key.age"`
- `defaults.bootstrapKey = "data/secrets/nixbot/nixbot.key.age"`
- `defaults.bootstrapUser = "pvl"` (or your chosen bootstrap account)
- `knownHosts = null` means temporary `ssh-keyscan` host pinning.
- `hosts.<name>.ageIdentityKey` can define the host-specific runtime age key
  secret to inject.

## Operational Notes

- `--action check-bootstrap` validates bootstrap key availability/decryption
  without build/deploy.
- `--bootstrap` forces bootstrap path usage even when primary `user@host` is
  reachable.
- `--dry` prints deploy commands; it does not perform remote activation.
- Per-run bootstrap readiness is cached to avoid duplicate fallback checks
  during snapshot + deploy phases.
- Host age identity injection is idempotent: deploy skips replacement when
  remote key checksum already matches configured `ageIdentityKey`.

## Rotation Runbooks

### Planned Rotation (Overlap-Capable)

1. Generate new keypairs for:
   - `nixbot` deploy/login key
   - `nixbot-bastion-ssh` ingress key
2. Add new public keys into `users/userdata.nix` lists while keeping old keys:
   - append to `nixbot.sshKeys`
   - append to `nixbot.bastionSshKeys`
3. Re-encrypt managed age files so both old and new nixbot public keys remain
   recipients:
   - `data/secrets/nixbot/nixbot.key.age`
   - `data/secrets/bastion/nixbot-bastion-ssh.key.age`
4. Deploy bastion first, then the rest of hosts.
5. Update CI secret `NIXBOT_BASTION_SSH_KEY` to the new bastion private key.
6. If you run `scripts/nixbot-deploy.sh` from outside bastion, also rotate
   `DEPLOY_BASTION_SSH_KEY_PATH` (forced-command bootstrap check key) to the new
   bastion ingress key file.
7. Validate forced-command access and one full deploy run.
8. Remove old public keys from both lists, re-encrypt again, and deploy.

### Bastion-First Single-Pass Cutover With Legacy Node Access

Use this when you want bastion on new keys immediately, but some nodes still
only trust the old `nixbot` key.

1. Prepare two deploy key secrets:
   - new key: `data/secrets/nixbot/nixbot.key.age` (or another chosen path)
   - legacy key: `data/secrets/nixbot/nixbot-legacy.key.age`
2. Add recipients for the legacy file in `data/secrets/default.nix` so
   `scripts/age-secrets.sh` manages it.
3. Set defaults in `hosts/nixbot.nix` to the new key.
4. Add per-host `key` overrides for nodes that still require legacy auth, for
   example:
   - `hosts.<old-node>.key = "data/secrets/nixbot/nixbot-legacy.key.age";`
5. For nodes that still require old bootstrap injection material, also set:
   - `hosts.<old-node>.bootstrapKey = "data/secrets/nixbot/nixbot-legacy.key.age";`
6. Deploy bastion and switch CI ingress key to the new bastion key.
7. If applicable, switch `DEPLOY_BASTION_SSH_KEY_PATH` for local orchestrator
   runs to the new bastion ingress key.
8. Run deploys in phase 2 to migrate old nodes onto new public key trust.
9. Remove per-host legacy `key` and `bootstrapKey` overrides, remove legacy
   secret material, re-encrypt recipients without legacy keys.

Important: this flow is for controlled migration. If compromise is suspected, do
revoke-first incident rotation instead of overlap.

### Machine Age Identity Rotation (Per Host)

Default policy: no legacy overlap required.

Reason: deploy injects host machine key immediately before activation, so
activation always has the current identity.

Single-step rotation:

1. Generate new host machine keypair.
2. Re-encrypt `data/secrets/machine/<host>.key.age` with admin/deployer
   recipients.
3. Update any host secret recipients in `data/secrets/default.nix` to new
   machine public key.
4. Deploy host; script injects new `/var/lib/nixbot/.age/identity` before
   activation.

Optional overlap (only for unusual partial/out-of-band flows):

1. Keep previous key as `/var/lib/nixbot/.age/identity_legacy`.
2. Temporarily set
   `age.identityPaths = [ "/var/lib/nixbot/.age/identity" "/var/lib/nixbot/.age/identity_legacy" ]`.
3. Encrypt host secrets to both old and new machine recipients.
4. After successful migration, remove legacy recipient and legacy file/path.
