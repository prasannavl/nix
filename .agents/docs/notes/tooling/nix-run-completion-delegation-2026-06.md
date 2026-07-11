# Nix Run Completion Delegation

Implemented a repo-local Bash completion bridge for root-flake app invocations
through `nix run`. The bridge attaches to `nix`, recognizes supported `nix run`
patterns, rewrites the active completion context, and delegates argument
completion to the package-owned completion functions.

The root dev shell hook sources `pkgs/support/bash-completions/load.bash`, which
loads this bridge.

Supported delegated forms:

- `nix run .#nixbot -- ...` -> `_nixbot`
- `nix run .#data-migrator -- ...` -> `_data_migrator`
- `nix run .#migration-manager -- ...` -> `_migration_manager`

`migration-manager` is provided by the root app `migration-manager`, whose
package `meta.mainProgram` is `migration-manager`.

## Implementation Shape

- Add a sourceable repo-local bridge:
  `pkgs/support/bash-completions/nix-run-apps.bash`.
- Source existing package completion scripts from the bridge:
  - `pkgs/tools/nixbot/nixbot.bash`
  - `pkgs/tools/data-migrator/data-migrator.bash`
  - `pkgs/tool/migration-manager/migration-manager.bash`
- Capture the pre-existing completion function for `nix` when one is present.
- Register a wrapper completion for `nix`.
- Register direct script completion aliases for:
  - `./scripts/nixbot.sh`
  - `scripts/nixbot.sh`

## Delegation Rules

- Delegate only after the `--` separator. Before `--`, preserve the existing Nix
  completion behavior so Nix flags and flake refs stay owned by Nix.
- Match a fixed repo-local app table:
  - `nixbot` -> `_nixbot`
  - `data-migrator` -> `_data_migrator`
  - `migration-manager` -> `_migration_manager`
- For a recognized app ref, temporarily rewrite Bash completion globals:
  - original: `COMP_WORDS=(nix run .#nixbot -- --hosts ab)`
  - synthetic: `COMP_WORDS=(nixbot --hosts ab)`
  - adjust `COMP_CWORD` by subtracting the index after `--`
  - call the delegated function
  - restore `COMP_WORDS`, `COMP_CWORD`, `COMP_LINE`, and `COMP_POINT`
- Recognize repo-local refs first:
  - `.#app`
  - `./#app`
  - absolute repo refs ending in `#app`
- For non-matching cases, call the captured Nix completion if available. If
  there is no captured Nix completion, return no completions.

## Validation

- `shellcheck pkgs/support/bash-completions/nix-run-apps.bash`
- Source the bridge in `bashInteractive`.
- Synthetic completion checks:
  - `nix run .#nixbot -- --hosts ab<TAB>` suggests Abird hosts.
  - `nix run .#data-migrator -- --profile ab<TAB>` suggests profiles.
  - `nix run .#migration-manager -- remote on --host ab<TAB>` suggests nixbot
    hosts.
- Verify fallback still works for ordinary `nix` and `nix run` completion when a
  previous Nix completion function is available.
