# Incus Guest Tailscale Login 2026-03

## Durable state

- Tailscale auth wiring lives in the shared `lib/incus-machine.nix` path, not
  as ad hoc host-local setup.
- `services.tailscale.authKeyFile` points at an agenix-managed secret under the
  standard `data/secrets/tailscale/<host>.key.age` tree.
- The stored secret is a Tailscale OAuth client secret, not a pre-minted auth
  key; `tailscale up --auth-key=...` uses it to mint fresh tagged login keys.
- Persistent server semantics require `ephemeral = false`,
  `preauthorized = true`, and explicit advertised tags such as `tag:vm`.
- Secret wiring should tolerate the encrypted file not existing yet by gating
  it with `builtins.pathExists`.
- The reusable factory defaults the secret name from `hostName` but still
  allows an explicit override for future guests.
