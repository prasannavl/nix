# Deployment Decisions

This document describes the current `nixbot` deployment architecture and security model.

## Current Model
- Bastion host: `pvl-x2` (`hosts/pvl-x2/default.nix`, imports `lib/nixbot/bastion.nix`)
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
  - `users/userdata.nix` (`nixbot.bastionSshKeys`, fallback `nixbot.bastionSshKey`)
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
  - `data/secrets/nixbot.key.age`
- Legacy optional install source:
  - `data/secrets/nixbot-legacy.key.age`
- Age bootstrap identity path:
  - `/var/lib/nixbot/.ssh/id_ed25519`
  - `/var/lib/nixbot/.ssh/id_ed25519_legacy` (when legacy key exists)

## Bastion Wiring Requirements
In `lib/nixbot/bastion.nix`:
- Add forced-command authorized key entry for `bastionSshKey`.
- Install current script to stable path:
  - `install -m 0755 ${../../scripts/nixbot-deploy.sh} /var/lib/nixbot/nixbot-deploy.sh`
- Ensure runtime prerequisites:
  - `/var/lib/nixbot/.ssh` exists, mode `0700`, owner `nixbot`
  - `environment.systemPackages` includes `age` and `jq`
- Ensure nixbot SSH client identity order includes both current and legacy key paths during rotation.

## Bootstrap Strategy
`hosts/nixbot.nix` supports bootstrap fallback fields:
- `bootstrapKey` (defaults + optional per-host override)
- `bootstrapUser`
- `bootstrapKeyPath`

During deploy, script behavior is:
1. Build host system closure.
2. Attempt primary target (`nixbot@host`) shell reachability.
3. If primary shell access fails, run forced-command bootstrap check (`--action check-bootstrap`) via bastion key.
4. If bootstrap check still fails, inject bootstrap key using bootstrap user path.
5. Continue deployment (currently via `nixos-rebuild --target-host`).
6. `--bootstrap` skips step 2 probing and forces bootstrap target selection for deploy/snapshot/rollback operations.

Important: successful forced-command bootstrap check does not imply general shell access for `nixos-rebuild --target-host`.

## Deploy Config Defaults (`hosts/nixbot.nix`)
- `defaults.user = "nixbot"`
- `defaults.key = "data/secrets/nixbot.key.age"`
- `defaults.bootstrapKey = "data/secrets/nixbot.key.age"`
- `defaults.bootstrapUser = "root"` (or your chosen bootstrap account)
- `knownHosts = null` means temporary `ssh-keyscan` host pinning.

## Operational Notes
- `--action check-bootstrap` validates bootstrap key availability/decryption without build/deploy.
- `--bootstrap` forces bootstrap path usage even when primary `user@host` is reachable.
- `--dry` prints deploy commands; it does not perform remote activation.
- Per-run bootstrap readiness is cached to avoid duplicate fallback checks during snapshot + deploy phases.

## Rotation Runbooks

### Planned Rotation (Overlap-Capable)
1. Generate new keypairs for:
   - `nixbot` deploy/login key
   - `nixbot-bastion-ssh` ingress key
2. Add new public keys into `users/userdata.nix` lists while keeping old keys:
   - append to `nixbot.sshKeys`
   - append to `nixbot.bastionSshKeys`
3. Re-encrypt managed age files so both old and new nixbot public keys remain recipients:
   - `data/secrets/nixbot.key.age`
   - `data/secrets/nixbot-bastion-ssh.key.age`
4. Deploy bastion first, then the rest of hosts.
5. Update CI secret `NIXBOT_BASTION_SSH_KEY` to the new bastion private key.
6. If you run `scripts/nixbot-deploy.sh` from outside bastion, also rotate `DEPLOY_BASTION_SSH_KEY_PATH` (forced-command bootstrap check key) to the new bastion ingress key file.
7. Validate forced-command access and one full deploy run.
8. Remove old public keys from both lists, re-encrypt again, and deploy.

### Bastion-First Single-Pass Cutover With Legacy Node Access
Use this when you want bastion on new keys immediately, but some nodes still only trust the old `nixbot` key.

1. Prepare two deploy key secrets:
   - new key: `data/secrets/nixbot.key.age` (or another chosen path)
   - legacy key: `data/secrets/nixbot-legacy.key.age`
2. Add recipients for the legacy file in `data/secrets/default.nix` so `scripts/age-secrets.sh` manages it.
3. Set defaults in `hosts/nixbot.nix` to the new key.
4. Add per-host `key` overrides for nodes that still require legacy auth, for example:
   - `hosts.<old-node>.key = "data/secrets/nixbot-legacy.key.age";`
5. For nodes that still require old bootstrap injection material, also set:
   - `hosts.<old-node>.bootstrapKey = "data/secrets/nixbot-legacy.key.age";`
6. Deploy bastion and switch CI ingress key to the new bastion key.
7. If applicable, switch `DEPLOY_BASTION_SSH_KEY_PATH` for local orchestrator runs to the new bastion ingress key.
8. Run deploys in phase 2 to migrate old nodes onto new public key trust.
9. Remove per-host legacy `key` and `bootstrapKey` overrides, remove legacy secret material, re-encrypt recipients without legacy keys.

Important: this flow is for controlled migration. If compromise is suspected, do revoke-first incident rotation instead of overlap.
