# Nixbot Key Rotation Prep Playbook (Key Generation)

This playbook prepares key material for
`docs/ai/playbooks/nixbot-key-rotation-execution.md`.

## Confirmation Protocol (Mandatory)

One-time confirmation gate:

1. Agent prints the full workflow plan:
   - all commands it will run
   - expected outcomes for each step
2. Agent asks once: `Proceed with keygen workflow? (yes/no)`
3. If `yes`, execute steps sequentially without additional confirmations.
4. On failure, stop immediately and ask how to proceed.
5. On user stop/abort request, halt before next step.

Execution behavior:

- no additional prompts after initial `yes` unless a step fails.

## Inputs

- `KEYGEN_DIR`: local secure working dir (example:
  `/tmp/nixbot-rotation-YYYYMMDD`).
- `NEW_KEY_TAG`: short suffix for comments/file names (example: `2026q1`).
- `AGE_KEY_FILE`: identity file to encrypt secrets (defaults to
  `~/.ssh/id_ed25519` if unset).

## Outputs (For Execution Playbook)

- `NEW_NIXBOT_PUB`
- `NEW_BASTION_PUB`
- `NEW_NIXBOT_KEY_AGE` (usually `data/secrets/nixbot/nixbot.key.age` or staged
  path)
- `NEW_NIXBOT_KEY_PRIVATE` (private key file path for GitHub repo SSH deploy-key
  secret)
- `NEW_BASTION_KEY_PRIVATE` (private key file path for GitHub secret
  `NIXBOT_BASTION_SSH_KEY`)
- optional `LEGACY_NIXBOT_KEY_AGE` for bastion-first cutover mode

## Step 1: Create Secure Working Directory

Run:

```bash
install -d -m 700 "${KEYGEN_DIR}"
```

Expected outcome:

- working dir exists with mode `0700`.

## Step 2: Generate New Nixbot Deploy/Login Keypair

Run:

```bash
ssh-keygen -t ed25519 -a 64 -N '' -C "nixbot-deploy-${NEW_KEY_TAG}" -f "${KEYGEN_DIR}/nixbot.key"
```

Expected outcome:

- `${KEYGEN_DIR}/nixbot.key` and `${KEYGEN_DIR}/nixbot.key.pub` created.

## Step 3: Generate New Bastion Ingress Keypair

Run:

```bash
ssh-keygen -t ed25519 -a 64 -N '' -C "nixbot-bastion-github-actions-${NEW_KEY_TAG}" -f "${KEYGEN_DIR}/nixbot-bastion-ssh.key"
```

Expected outcome:

- `${KEYGEN_DIR}/nixbot-bastion-ssh.key` and
  `${KEYGEN_DIR}/nixbot-bastion-ssh.key.pub` created.

## Step 4: Validate Fingerprints

Run:

```bash
ssh-keygen -lf "${KEYGEN_DIR}/nixbot.key"
ssh-keygen -lf "${KEYGEN_DIR}/nixbot-bastion-ssh.key"
```

Expected outcome:

- fingerprints printed and recorded for change log.

## Step 5: Stage Public Keys Into Repo Metadata

Actions:

1. Update `users/userdata.nix` key lists:
   - append contents of `${KEYGEN_DIR}/nixbot.key.pub` to `nixbot.sshKeys`
   - append contents of `${KEYGEN_DIR}/nixbot-bastion-ssh.key.pub` to
     `nixbot.bastionSshKeys`
2. Optionally refresh helper public-key files:
   - `data/secrets/nixbot/nixbot.pub`
   - `data/secrets/bastion/nixbot-bastion-ssh.key.pub`

Expected outcome:

- repo contains new public keys for overlap/cutover flow.

## Step 6: Encrypt New Private Keys To Age Files

Important:

- Do not commit plaintext private keys.
- Do not place plaintext `*.key` inside `data/secrets`.

Run (deterministic recipients from `data/secrets/default.nix`):

```bash
mapfile -t NIXBOT_RECIPS < <(nix eval --json --file data/secrets/default.nix | jq -r '."data/secrets/nixbot/nixbot.key.age".publicKeys[]')
mapfile -t BASTION_RECIPS < <(nix eval --json --file data/secrets/default.nix | jq -r '."data/secrets/bastion/nixbot-bastion-ssh.key.age".publicKeys[]')

NIXBOT_ARGS=(); for r in "${NIXBOT_RECIPS[@]}"; do NIXBOT_ARGS+=(-r "$r"); done
BASTION_ARGS=(); for r in "${BASTION_RECIPS[@]}"; do BASTION_ARGS+=(-r "$r"); done

age "${NIXBOT_ARGS[@]}" -o data/secrets/nixbot/nixbot.key.age "${KEYGEN_DIR}/nixbot.key"
age "${BASTION_ARGS[@]}" -o data/secrets/bastion/nixbot-bastion-ssh.key.age "${KEYGEN_DIR}/nixbot-bastion-ssh.key"
```

Preferred:

- run `scripts/age-secrets.sh encrypt data/secrets` if plaintext managed files
  already exist and recipient map is correct.

Expected outcome:

- updated `.age` files in `data/secrets`.

## Step 7: Manual CI Secret Update (No Key Output)

Actions:

1. Use local file `${KEYGEN_DIR}/nixbot.key` to update the GitHub secret used
   for repo SSH deploy-key auth (name per your repo settings).
2. Use local file `${KEYGEN_DIR}/nixbot-bastion-ssh.key` to update GitHub secret
   `NIXBOT_BASTION_SSH_KEY`.
3. Do not print, `cat`, or echo private key contents in agent output.

Expected outcome:

- GitHub repo SSH deploy-key secret updated to the rotated nixbot key.
- GitHub `NIXBOT_BASTION_SSH_KEY` updated without exposing key material in
  terminal logs.

## Step 8: Cleanup Local Plaintext Keys

After successful encryption and secure escrow:

```bash
shred -u "${KEYGEN_DIR}/nixbot.key" "${KEYGEN_DIR}/nixbot-bastion-ssh.key"
```

If `shred` unavailable, use secure deletion method approved for your platform.

Expected outcome:

- plaintext private keys removed from local working dir.

## Hand-off To Execution Playbook

Use generated values with:

- `docs/ai/playbooks/nixbot-key-rotation-execution.md`

Recommended next sequence:

1. Run execution playbook Mode A for overlap rotation from current repo state.
2. Remove old keys after validation deploys pass.
