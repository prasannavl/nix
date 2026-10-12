# Bash prompt: no `tput`

## Symptom

VS Code Remote terminal start on `pvl-l5`:

```console
tput: command not found
tput: command not found
```

Two errors, normal prompt after.

## Root cause

- Errors = 2 `tput` calls in `users/pvl/bash/bashrc.d/101-bash-prompt.sh`
  (`setup_ps1`, `sgr0`/`bold`). `tput` = `ncurses`, normally in
  `/run/current-system/sw/bin`.
- That shell's `PATH` was the repo `nix develop` dev-shell PATH.
  `pkgs.mkShell { packages = rootPackages; }` (`lib/flake/dev-shells.nix`,
  `rootPackages` in `lib/flake/root.nix`) sets `PATH` to only that closure: no
  `ncurses`, no system path.
- Terminal was already in the dev shell before `.bashrc`: `mkhl.direnv` caches
  the direnv env into `context.environmentVariableCollection`
  (`this.environment.replace("PATH", ...)`), applied to new terminals, replacing
  `PATH`. direnv's own hook then sees matching `DIRENV_DIFF` and does nothing,
  so the system path is never re-added. Plain shells append it
  (`direnv exec .`), VS Code does not.
- Deploy not the cause: home-manager gens 170/171 have byte-identical `.bashrc`,
  `.profile`, `hm-session-vars.sh`, `101-bash-prompt.sh`; only
  niri/fonts/pi-extension changed. Trigger = workspace dev shell regenerated
  (`.direnv/flake-profile-*`, 16:50), so the extension refreshed and injected.

## Rule

Interactive bash prompt stays dependency-free: literal SGR escapes, no
`tput`/`setaf`/`setab` (devShell PATH is intentionally lean).

## Change

`users/pvl/bash/bashrc.d/101-bash-prompt.sh`:

```bash
r="\[\033[0m\]"
b="\[\033[1m\]"
```

## Validation

- Dev-shell-only PATH (no `tput`), source prompt: no errors, valid `PS1`.
- Full system PATH: same prompt shape.
- `shfmt -d` clean.

## Related

- `.agents/docs/notes/tooling/pvl-vscode-direnv-devshells-2026-04.md`.
