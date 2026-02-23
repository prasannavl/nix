# Deployment Decisions

This document records the deployment architecture and key-handling decisions for `nixbot`.

## Current Model

- Bastion host: `pvl-x2` (`hosts/pvl-x2/default.nix`, imports `lib/nixbot/bastion.nix`)
- Deploy orchestration: `scripts/nixbot-deploy.sh`
- Deploy mapping/config: `hosts/nixbot.nix`
- Secrets storage: `data/secrets/*.key` (SOPS-encrypted)

## Key Roles

### 1) GitHub Actions -> Bastion

- Keypair: `nixbot-bastion-ssh.key` / `nixbot-bastion-ssh.key.pub`
- Private key is used only by GitHub Actions (`NIXBOT_BASTION_SSH_KEY`).
- Public key is restricted on bastion with forced command:
  - `/var/lib/nixbot/ssh-gate.sh`
- Config source:
  - `users/userdata.nix` (`nixbot.bastionSshKey`)
  - `lib/nixbot/bastion.nix`

### 2) Bastion -> Target Hosts + Repo Deploy Key

- Keypair: `nixbot.key` / `nixbot.pub`
- `nixbot.pub` is the authorized deploy key on target hosts.
- `nixbot.key` is SOPS-encrypted at `data/secrets/nixbot.key`.
- Deploy script uses this key directly (after decrypt-in-place):
  - `hosts/nixbot.nix` defaults:
    - `user = "nixbot"`
    - `key = "data/secrets/nixbot.key"`

### 3) sops-nix Runtime Decryption on Bastion

- On bastion, `sops-nix` installs `nixbot.key` to:
  - `/var/lib/nixbot/.ssh/id_ed25519`
- `sops-nix` decrypts using SSH identity path:
  - `sops.age.sshKeyPaths = [ "/var/lib/nixbot/.ssh/id_ed25519" ]`
- Config source: `lib/nixbot/bastion.nix`

## Bootstrap Strategy

Bootstrap is intentionally simple and does **not** rotate or inject SSH host keys.

- `hosts/nixbot.nix` has per-host optional:
  - `bootstrapNixbotKey = "data/secrets/nixbot.key"`
- During deploy, `scripts/nixbot-deploy.sh`:
  - decrypts secrets in `data/secrets` in place
  - injects decrypted `nixbot.key` to target:
    - `/var/lib/nixbot/.ssh/id_ed25519`
  - applies perms/ownership (`0400`, `nixbot:nixbot` when user exists)
  - continues with `nixos-rebuild`

This avoids touching `/etc/ssh/ssh_host_*` keys entirely.

## Why This Model

- One deploy key source of truth: `data/secrets/nixbot.key`
- Simpler key rotation and less moving parts
- No host-key mutation during deploy (avoids known_hosts churn)
- Keeps GH ingress key separated from internal deploy key

## Key Rotation Procedure

1. Add new deploy public key to all target hosts (keep old key temporarily).
2. Replace and re-encrypt `data/secrets/nixbot.key`.
3. Deploy all hosts.
4. Remove old public key from authorized keys.

If needed, keep `bootstrapNixbotKey` configured during transition.

## Operational Notes

- `scripts/nixbot-deploy.sh` decrypts secrets in place and re-encrypts on cleanup.
- `--dry` does not perform decrypt/inject steps.
- `knownHosts = null` means deploy script uses `ssh-keyscan` for temporary host pinning file.
- For strict pinning, set `knownHosts` per host in `hosts/nixbot.nix`.
- To prevent committing plaintext secrets, enable repo hooks once:
  - `scripts/git-install-hooks.sh`
  - This enables `.githooks/pre-commit`, which validates staged `data/secrets/*.key` files are valid SOPS-encrypted blobs.
