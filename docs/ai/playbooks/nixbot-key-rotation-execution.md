# Nixbot Key Rotation Execution Playbook (Agent-Driven)

This playbook is for agents executing rotation phases with explicit user
confirmation at each step.

## Operator Inputs (Required)

Set these before execution:

- `NEW_NIXBOT_PUB`: new public key for normal nixbot login/deploy.
- `NEW_CI_PUB`: new public key for CI/local forced-command ingress.
- `NEW_NIXBOT_KEY_AGE`: age file path for new deploy private key (example:
  `data/secrets/nixbot/nixbot.key.age`).
- `NEW_NIXBOT_KEY_PRIVATE`: path to new nixbot deploy private key file used for
  GitHub repo SSH access.
- `NEW_CI_KEY_PRIVATE`: path to new CI host private key file used by CI/local
  SSH calls.

Sensitive handling:

- Never print, `cat`, or echo `NEW_NIXBOT_KEY_PRIVATE` contents in terminal
  output.
- Never print, `cat`, or echo `NEW_CI_KEY_PRIVATE` contents in terminal output.
- Use path-only handling and manual secret updates for GitHub secrets.

Optional for CI host-first cutover:

- `LEGACY_NIXBOT_KEY_AGE`: age file path containing old deploy private key
  material (example: `data/secrets/nixbot/nixbot-legacy.key.age`).
- `LEGACY_NODES`: comma-separated nodes still requiring old key trust.

## Bootstrap Overwrite Rule (Critical)

- Bootstrap injection writes the selected bootstrap private key to
  `/var/lib/nixbot/.ssh/id_ed25519` on the target.
- On replacement, previous key should be retained at
  `/var/lib/nixbot/.ssh/id_ed25519_legacy`.
- On the CI host, that file is also the deploy identity used to SSH from CI host
  to other hosts.
- CI host nixbot SSH client should attempt both identities (`id_ed25519`, then
  `id_ed25519_legacy`) during overlap.
- During rotation, if CI host is bootstrapped with the new key before legacy
  hosts trust that key, CI host can lose SSH access to legacy hosts.
- Therefore, when legacy hosts still require old trust, keep and use
  `LEGACY_NIXBOT_KEY_AGE` for those nodes (including `bootstrapKey` where
  applicable) until migration is complete.

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

Mode A safety precondition:

- Only use Mode A if all target hosts already trust `NEW_NIXBOT_PUB` before CI
  host switches to `NEW_NIXBOT_KEY_AGE`.
- If any host may still require the old deploy key for SSH auth, use Mode B with
  `LEGACY_NIXBOT_KEY_AGE`.

### Step 1: Add New Public Keys (Overlap)

Edit `users/userdata.nix`:

- append `NEW_NIXBOT_PUB` to `nixbot.sshKeys`
- append `NEW_CI_PUB` to `nixbot.ciSshKeys`

Expected outcome:

- both old+new keys present in lists.

### Step 2: Re-encrypt Managed Secrets

Run:

```bash
scripts/age-secrets.sh encrypt data/secrets
```

Expected outcome:

- managed `.age` files updated with recipients from `data/secrets/default.nix`.
- active deploy key material remains compatible with hosts targeted in Step 5
  (or Mode B is used).

### Step 3: Deploy CI Host First

Run:

```bash
nixbot deploy --hosts <ci-host> --force
```

Expected outcome:

- CI host has updated authorized_keys and runtime key material.

### Step 4: Switch CI/Local Forced-Command Key

Actions:

- update GitHub secret used for repo SSH deploy-key auth (nixbot deploy key;
  name per your repo settings) to `NEW_NIXBOT_KEY_PRIVATE`.
- update GitHub secret `NIXBOT_CI_SSH_KEY` to new private key.
- if running local orchestrator checks, set `NIXBOT_CI_SSH_KEY_PATH` to new CI
  host key age file/path.
- do not print private key material during this step.

Expected outcome:

- GitHub workflows can still clone/fetch the repository over SSH with the
  rotated nixbot key.
- forced-command calls authenticate with new ingress key.

### Step 5: Validate End-to-End

Run:

```bash
nixbot check-bootstrap --hosts <ci-host> --force
nixbot deploy --hosts all --force
```

Expected outcome:

- bootstrap checks pass.
- deploy succeeds with overlap keys.

### Step 6: Remove Old Public Keys (Cut)

Edit `users/userdata.nix`:

- remove old entry from `nixbot.sshKeys`
- remove old entry from `nixbot.ciSshKeys`

Then run:

```bash
scripts/age-secrets.sh encrypt data/secrets
nixbot deploy --hosts all --force
```

Expected outcome:

- only new keys trusted.

## Mode B: CI Host First Single-Pass Cutover (Legacy Nodes Allowed)

### Step 1: Configure New Keys + Legacy Paths

1. Add new pubkeys in `users/userdata.nix` as in Mode A.
2. Ensure `LEGACY_NIXBOT_KEY_AGE` exists and is listed in
   `data/secrets/default.nix`.
3. In `hosts/nixbot.nix`:
   - keep defaults on new key (`defaults.key = NEW_NIXBOT_KEY_AGE`)
   - keep bootstrap defaults on new key
     (`defaults.bootstrapKey = NEW_NIXBOT_KEY_AGE`)
   - for each legacy node add:
     - `hosts.<node>.key = LEGACY_NIXBOT_KEY_AGE`
     - `hosts.<node>.bootstrapKey = LEGACY_NIXBOT_KEY_AGE`

Expected outcome:

- CI host/new nodes can use new key.
- old nodes temporarily pinned to legacy key.

### Step 2: Re-encrypt Secrets

Run:

```bash
scripts/age-secrets.sh encrypt data/secrets
```

Expected outcome:

- all relevant age files current.

### Step 3: Deploy CI host + Rotate Ingress

Run:

```bash
nixbot deploy --hosts <ci-host> --force
```

Then rotate:

- GitHub secret used for repo SSH deploy-key auth (nixbot deploy key; name per
  your repo settings) to new private key.
- GitHub `NIXBOT_CI_SSH_KEY` to new private key.
- local `NIXBOT_CI_SSH_KEY_PATH` to new key path (if used).

Expected outcome:

- CI host is on new key model.
- GitHub workflows retain repo SSH access after key rotation.
- ingress auth uses new CI host key.
- CI host deploy identity at `/var/lib/nixbot/.ssh/id_ed25519` remains
  compatible with any still-legacy hosts you need to reach next.

### Step 4: Phase-2 Migrate Legacy Nodes

Run deploy for legacy nodes first, then all:

```bash
nixbot deploy --hosts "<legacy1,legacy2>" --force
nixbot deploy --hosts all --force
```

Expected outcome:

- legacy nodes now trust new public keys.
- after this point, CI host can safely run with only new deploy identity.

### Step 5: Remove Legacy Overrides + Material

1. Remove per-host `key` and `bootstrapKey` legacy overrides from
   `hosts/nixbot.nix`.
2. Remove legacy recipients/secret usage.
3. Re-encrypt and deploy:

```bash
scripts/age-secrets.sh encrypt data/secrets
nixbot deploy --hosts all --force
```

Expected outcome:

- no legacy key dependencies remain.

## Incident Rule

If compromise is suspected, do not use overlap rotation across compromised trust
boundaries. Use revoke-first incident procedure.
