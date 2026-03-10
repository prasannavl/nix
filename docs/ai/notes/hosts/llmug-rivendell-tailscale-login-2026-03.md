# llmug-rivendell Tailscale Login 2026-03

- Added `age.secrets.tailscale-auth-key` to `hosts/llmug-rivendell/default.nix`.
- Set `services.tailscale.authKeyFile` to the decrypted agenix secret path so
  NixOS `tailscaled-autoconnect` can run `tailscale up` automatically.
- Registered `data/secrets/tailscale/llmug-rivendell.key.age` in
  `data/secrets/default.nix` with recipients `admins ++ llmug-rivendell`.
- Guarded the host-side secret wiring with `builtins.pathExists` so evaluation
  still succeeds before the encrypted secret is added.
- Corrected after user clarification to keep this under the standard
  `data/secrets` tree.
