# Bash Completions

Added Bash completion sources for operator CLIs:

- `pkgs/support/bash-completions/load.bash`
  - sourceable repo-local entrypoint for all repo-local completion glue;
  - sourced automatically by the root `default` and `full` dev shells;
  - loads `nix-run-apps.bash` and `age-secrets.bash`.
- `scripts/bash-completions-source.bash`
  - short sourceable alias for humans and shell startup files;
  - delegates to `pkgs/support/bash-completions/load.bash`.

- `pkgs/tools/nixbot/nixbot.bash`
  - installed by the `nixbot` package;
  - completes top-level actions, Terraform project actions, option names,
    enumerated option values, file-path options, and
    `--group`/`--host`/`--hosts` selections from `hosts/nixbot.nix`;
  - completes `--host value` and `--host=value` with exact hosts only;
  - completes `--group value` and `--group=value` with exact groups;
  - supports `--hosts value`, `--hosts=value`, comma-separated host selectors,
    quoted space-separated host selectors, and host exclusions.
- `pkgs/tools/data-migrator/data-migrator.bash`
  - installed by the `data-migrator` package;
  - completes profiles from packaged YAML profiles or
    `pkgs/tools/data-migrator/profiles.nix`;
  - completes nixbot-backed host arguments from `hosts/nixbot.nix`;
  - registers `data-migrator`.
- `pkgs/tool/migration-manager/migration-manager.bash`
  - installed by the `migration-manager` package;
  - completes local actions, `remote` actions, remote options, and `--host` from
    `hosts/nixbot.nix`;
  - follows `MIGRATION_MANAGER_NIXBOT_CONFIG` when set.
- `pkgs/support/bash-completions/age-secrets.bash`
  - sourceable repo-local completion for `scripts/age-secrets.sh`;
  - completes modes and managed secret paths from `data/secrets/default.nix`.

The rebased worktree includes a standalone `migration-manager` package exporting
`migration-manager`, so `migration-manager` completion is owned by that package
rather than the `data-migrator` package.

The root `default` and `full` dev shells source
`pkgs/support/bash-completions/load.bash` from their shell hook when entered
from programmable Bash. The hook resolves the live Git worktree first and falls
back to the flake source snapshot, so ordinary `nix develop` sessions pick up
repo-local completion glue automatically.

For shells that enter the repo through `direnv` or start a child Bash via
`nix develop --command`, source `scripts/bash-completions-source.bash` from the
interactive Bash startup path. Bash completion functions and `complete`
registrations are shell-local state, so `direnv` cannot export them into the
parent shell.
