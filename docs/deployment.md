# Deployment Decisions

This document records the deployment architecture and key-handling model for `nixbot`.

## Current Model

- Bastion host: `pvl-x2` (`hosts/pvl-x2/default.nix`, imports `lib/nixbot/bastion.nix`)
- Deploy orchestration: `scripts/nixbot-deploy.sh`
- Deploy mapping/config: `hosts/nixbot.nix`
- Secrets storage: `data/secrets/*.age` (age/agenix)

## Key Roles

### 1) GitHub Actions -> Bastion

- Keypair: `nixbot-bastion-ssh.key` / `nixbot-bastion-ssh.key.pub`
- Public key is restricted on bastion with forced command:
  - `/var/lib/nixbot/ssh-gate.sh`
- Config source:
  - `users/userdata.nix` (`nixbot.bastionSshKey`)
  - `lib/nixbot/bastion.nix`

### 2) Bastion -> Target Hosts + Repo Deploy Key

- Keypair: `nixbot.key` / `nixbot.pub`
- `nixbot.pub` is the authorized deploy key on target hosts.
- Encrypted secret file:
  - `data/secrets/nixbot.key.age`
- Deploy mapping defaults (`hosts/nixbot.nix`):
  - `user = "nixbot"`
  - `key = "data/secrets/nixbot.key.age"`

### 3) Runtime Secret Install on Bastion (agenix)

- `agenix` installs the deploy key to:
  - `/var/lib/nixbot/.ssh/id_ed25519`
- Decryption identity path (bootstrap key):
  - `age.identityPaths = [ "/var/lib/nixbot/.ssh/bootstrap_id_ed25519" ]`
- Config source: `lib/nixbot/bastion.nix`

## Bootstrap Strategy

- `hosts/nixbot.nix` supports per-host:
  - `bootstrapNixbotKey = "data/secrets/nixbot.key.age"`
- During deploy, `scripts/nixbot-deploy.sh`:
  - decrypts `*.age` key files using local age identity file (`AGE_KEY_FILE`)
  - injects bootstrap key to:
    - `/var/lib/nixbot/.ssh/bootstrap_id_ed25519`
  - continues with `nixos-rebuild`

## Recipients

- agenix recipients file:
  - `data/secrets/default.nix`
- This maps each `*.age` secret path to recipient public keys.

## Operational Notes

- `--dry` does not perform remote injection.
- `knownHosts = null` means deploy script uses `ssh-keyscan` for temporary host pinning.
- For strict pinning, set `knownHosts` per host in `hosts/nixbot.nix`.
