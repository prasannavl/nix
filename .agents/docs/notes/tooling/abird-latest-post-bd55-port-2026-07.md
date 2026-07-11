# Abird Latest Post-bd55 Port 2026-07

Reviewed the newest three commits on `abird/master` after `bd552f84`, ending at
`928a0a72`, from local base `3e2edb2e`.

## Logical Units

- Flake Codex input cleanup: `7cd6313e` was already present locally. The local
  root flake has no `codex` input and the lock graph has no `codex` or
  `rust-overlay` nodes.
- Flake input refresh: `2ecf7610` was already present locally by root-input
  equivalence. Local `root.inputs.nixpkgs` points at `nixpkgs_2`, whose locked
  revision matches Abird's refreshed `nixpkgs` revision. The separate local
  `nixpkgs` node belongs to local-only input graph structure and should not be
  compared as the root input.
- External tool pins: `928a0a72` was already present locally with byte-identical
  shared `lib/ext` pin files.

## Commit Ledger

| Commit     | Subject                           | Disposition                                                                                                                            |
| ---------- | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `928a0a72` | `chore(ext): update pinned tools` | Already present locally; `lib/ext/{stalwart-cli,tailscale,vscode}/default.nix` are byte-identical to `abird/master`.                   |
| `2ecf7610` | `chore(flake): refresh inputs`    | Already present locally by root-input equivalence for `crane`, `home-manager`, root `nixpkgs`, `unstable`, and `vscode-ext`.           |
| `7cd6313e` | `chore(flake): drop codex input`  | Already present locally; the root flake and lock graph do not retain the removed Abird `codex` input or its `rust-overlay` dependency. |

## Byte-Parity Targets

The shared byte-parity set for this audit is:

- `lib/ext/stalwart-cli/default.nix`
- `lib/ext/tailscale/default.nix`
- `lib/ext/vscode/default.nix`

## Intentional Divergences

- `flake.nix` and `flake.lock` were not copied byte-for-byte from Abird. This
  repo intentionally carries local-only inputs such as `antigravity`,
  `llm-agents`, `nix-alien`, `nixos-hardware`, `noctalia`, `p7-borders`,
  `p7-cmds`, and `treefmt-nix`.
- Local `flake.lock` includes a dependency node named `nixpkgs` for local-only
  graph consumers, while the root input `nixpkgs` maps to `nixpkgs_2`. The root
  input is the relevant parity check for Abird's `nixos-26.05` refresh.
