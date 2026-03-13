# Incus Machine Tailscale Block Refactor 2026-03

## Decision

- Grouped all reusable Tailscale-specific logic in `lib/incus-machine.nix`
  into one cohesive conditional block at the end of the module.
- Kept the existing behavior: the guest only wires the secret and
  `services.tailscale` settings when the encrypted
  `data/secrets/tailscale/<name>.key.age` file exists.
- Simplified the block to a single local secret path and an inline derived
  `builtins.path` for the agenix file input.
- Tightened the final form further by using a single-character local for the
  throwaway path binding inside the final Tailscale block.

## Rationale

- The prior module still left Tailscale-specific secret discovery in a
  separate top-level `let`, away from the actual `services.tailscale`
  configuration.
- Keeping the path lookup and conditional module fragment together makes the
  Tailscale block self-contained and easier to modify without touching the
  rest of the module.
