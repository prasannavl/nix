# Deployment Decisions

This document describes the current `nixbot` deployment architecture and
security model.

## Current Model

- Bastion host: `pvl-x2` (`hosts/pvl-x2/default.nix`, imports
  `lib/nixbot/bastion.nix`)
- Deploy orchestration script: `scripts/nixbot-deploy.sh`
- Deploy mapping/config: `hosts/nixbot.nix`
- Secrets storage: `data/secrets/*.age` (age/agenix)

## Key Roles

### 1) CI -> Bastion (`nixbot@pvl-x2`)

- CI uses a dedicated bastion ingress key (`nixbot-bastion-ssh`).
- That key is forced-command-only on bastion:
  - command: `/var/lib/nixbot/nixbot-deploy.sh`
  - no shell / no forwarding flags.
- Source of key material:
  - `users/userdata.nix` (`nixbot.bastionSshKeys`, fallback
    `nixbot.bastionSshKey`)
  - wired by `lib/nixbot/bastion.nix`

### 2) Regular `nixbot` SSH Key

- `nixbot.sshKeys` are regular SSH keys for non-forced-command access.
- The singular `nixbot.sshKey` is retained as a backward-compatible alias.
- It is defined by the base nixbot user module (`lib/nixbot/default.nix`).
- Bastion module does not override/remove it.

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

`hosts/nixbot.nix` supports bootstrap fallback fields:

- `bootstrapKey` (defaults + optional per-host override)
- `bootstrapUser`
- `bootstrapKeyPath`

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

## Deploy Config Defaults (`hosts/nixbot.nix`)

- `defaults.user = "nixbot"`
- `defaults.key = "data/secrets/nixbot/nixbot.key.age"`
- `defaults.bootstrapKey = "data/secrets/nixbot/nixbot.key.age"`
- `defaults.bootstrapUser = "root"` (or your chosen bootstrap account)
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
