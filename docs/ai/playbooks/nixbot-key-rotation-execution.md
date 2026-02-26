# Nixbot Key Rotation Execution Playbook (Agent-Driven)

This playbook is for agents executing rotation phases with explicit user confirmation at each step.

## Operator Inputs (Required)

Set these before execution:

- `NEW_NIXBOT_PUB`: new public key for normal nixbot login/deploy.
- `NEW_BASTION_PUB`: new public key for CI/local forced-command ingress.
- `NEW_NIXBOT_KEY_AGE`: age file path for new deploy private key (example: `data/secrets/nixbot.key.age`).
- `NEW_BASTION_KEY_PRIVATE`: path to new bastion private key file used by CI/local SSH calls.

Optional for bastion-first cutover:

- `LEGACY_NIXBOT_KEY_AGE`: age file path containing old deploy private key material (example: `data/secrets/nixbot-legacy.key.age`).
- `LEGACY_NODES`: comma-separated nodes still requiring old key trust.

## Confirmation Protocol (Mandatory)

Before every step:
1. Agent prints:
   - Step number
   - exact command(s) it will run
   - expected outcome
2. Agent asks: `Proceed with Step <N>? (yes/no)`
3. Agent executes only on explicit `yes`.
4. On failure, stop and ask how to proceed.

## Mode A: Planned Overlap Rotation

### Step 1: Add New Public Keys (Overlap)
Edit `users/userdata.nix`:
- append `NEW_NIXBOT_PUB` to `nixbot.sshKeys`
- append `NEW_BASTION_PUB` to `nixbot.bastionSshKeys`

Expected outcome:
- both old+new keys present in lists.

### Step 2: Re-encrypt Managed Secrets
Run:

```bash
scripts/age-secrets.sh encrypt data/secrets
```

Expected outcome:
- managed `.age` files updated with recipients from `data/secrets/default.nix`.

### Step 3: Deploy Bastion First
Run:

```bash
./scripts/nixbot-deploy.sh --hosts pvl-x2 --action deploy --force
```

Expected outcome:
- bastion has updated authorized_keys and runtime key material.

### Step 4: Switch CI/Local Forced-Command Key
Actions:
- update GitHub secret `NIXBOT_BASTION_SSH_KEY` to new private key.
- if running local orchestrator checks, set `DEPLOY_BASTION_SSH_KEY_PATH` to new bastion key age file/path.

Expected outcome:
- forced-command calls authenticate with new ingress key.

### Step 5: Validate End-to-End
Run:

```bash
./scripts/nixbot-deploy.sh --hosts pvl-x2 --action check-bootstrap --force
./scripts/nixbot-deploy.sh --hosts all --action deploy --force
```

Expected outcome:
- bootstrap checks pass.
- deploy succeeds with overlap keys.

### Step 6: Remove Old Public Keys (Cut)
Edit `users/userdata.nix`:
- remove old entry from `nixbot.sshKeys`
- remove old entry from `nixbot.bastionSshKeys`

Then run:

```bash
scripts/age-secrets.sh encrypt data/secrets
./scripts/nixbot-deploy.sh --hosts all --action deploy --force
```

Expected outcome:
- only new keys trusted.

## Mode B: Bastion-First Single-Pass Cutover (Legacy Nodes Allowed)

### Step 1: Configure New Keys + Legacy Paths
1. Add new pubkeys in `users/userdata.nix` as in Mode A.
2. Ensure `LEGACY_NIXBOT_KEY_AGE` exists and is listed in `data/secrets/default.nix`.
3. In `hosts/nixbot.nix`:
   - keep defaults on new key (`defaults.key = NEW_NIXBOT_KEY_AGE`)
   - for each legacy node add:
     - `hosts.<node>.key = LEGACY_NIXBOT_KEY_AGE`
     - `hosts.<node>.bootstrapNixbotKey = LEGACY_NIXBOT_KEY_AGE`

Expected outcome:
- bastion/new nodes can use new key.
- old nodes temporarily pinned to legacy key.

### Step 2: Re-encrypt Secrets
Run:

```bash
scripts/age-secrets.sh encrypt data/secrets
```

Expected outcome:
- all relevant age files current.

### Step 3: Deploy Bastion + Rotate Ingress
Run:

```bash
./scripts/nixbot-deploy.sh --hosts pvl-x2 --action deploy --force
```

Then rotate:
- GitHub `NIXBOT_BASTION_SSH_KEY` to new private key.
- local `DEPLOY_BASTION_SSH_KEY_PATH` to new key path (if used).

Expected outcome:
- bastion is on new key model.
- ingress auth uses new bastion key.

### Step 4: Phase-2 Migrate Legacy Nodes
Run deploy for legacy nodes first, then all:

```bash
./scripts/nixbot-deploy.sh --hosts "<legacy1,legacy2>" --action deploy --force
./scripts/nixbot-deploy.sh --hosts all --action deploy --force
```

Expected outcome:
- legacy nodes now trust new public keys.

### Step 5: Remove Legacy Overrides + Material
1. Remove per-host `key` and `bootstrapNixbotKey` legacy overrides from `hosts/nixbot.nix`.
2. Remove legacy recipients/secret usage.
3. Re-encrypt and deploy:

```bash
scripts/age-secrets.sh encrypt data/secrets
./scripts/nixbot-deploy.sh --hosts all --action deploy --force
```

Expected outcome:
- no legacy key dependencies remain.

## Incident Rule

If compromise is suspected, do not use overlap rotation across compromised trust boundaries.
Use revoke-first incident procedure.
