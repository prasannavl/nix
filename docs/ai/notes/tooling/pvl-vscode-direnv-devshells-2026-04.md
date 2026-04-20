# VSCode direnv + flake devShells

## Context

- Root flake previously had no `devShells` output. Opening the repo in VS Code
  triggered `arrterian.nix-env-selector`, which runs
  `nix-shell flake.nix --run export`. Flakes are not single derivations, so the
  call failed with `nix-shell requires a single derivation`. Extension was
  unmaintained (last release 2022).
- Child flakes under `pkgs/` already expose their own per-package `devShell` via
  `pkg-helper.nix` and were intentionally kept self-contained.

## Decisions

- Replace `arrterian.nix-env-selector` with `mkhl.direnv` (VS Code direnv
  integration) in `users/pvl/vscode/default.nix`. Extension is current and reads
  env from any `.envrc` direnv loads.
- Enable `programs.direnv` with `nix-direnv` in a new
  `users/pvl/direnv/default.nix` Home Manager module. Wire it through
  `users/pvl/default.nix` `desktop-gnome-modules`, alongside `./vscode`.
  `config.global.hide_env_diff = true` to suppress per-shell env diffs.
- Add `lib/flake/dev-shells.nix` as the dedicated abstraction for repo-level
  devShells. Exposes `mkDefault`, `mkFull`, and `mkDevShells`. Lives in
  `lib/flake/` next to `packages.nix` and `apps.nix`.
- Root flake `devShells.<system>.default` is intentionally lean: nix authoring
  tools only (`alejandra`, `git`, `jq`, `nix`, `nix-output-monitor`, `nvd`,
  `agenix`). Stays fast on `direnv allow` at the repo root.
- Root flake `devShells.<system>.full` aggregates every child package
  `passthru.devShell` discovered in `allOutputs.<system>.packages` via
  `mkShell.inputsFrom`. Opt-in: `nix develop .#full`. Designed to be removed by
  deleting the `mkFull` function in `lib/flake/dev-shells.nix` and the `full`
  attr from `mkDevShells` — default shell is unaffected.
- `.envrc` lives at the repo root (`use flake`) and in each child flake dir
  under `pkgs/examples/*` and `pkgs/cloudflare-apps/llmug-hello`. Direnv
  auto-switches per cwd.
- `pkgs/cloudflare-apps/llmug-hello/.gitignore` carves out `!.envrc` so the
  worker template's `.env*` rule does not swallow the file.
- Repo `.gitignore` now excludes `.direnv/` (direnv per-dir cache).
- `.vscode/settings.json` keeps only `direnv.restart.automatic = true`. Repo
  `/.vscode/` stays gitignored — change is local to the user's clone.

## How it composes

- `flake.nix` builds `devShellsFor system` per `allSystems`, then merges via
  `// { devShells = nixpkgs.lib.genAttrs allSystems devShellsFor; }`. Sits
  alongside `flakeLib.standardOutputsFrom` outputs.
- `mkFull` walks `childPackages` (the per-system package attrset returned by
  `flakeLib.outputsFor`), filters for `passthru.devShell`, and feeds them to
  `pkgs.mkShell { inputsFrom = ...; }`. Spot-check confirms Go, Node, Deno,
  Python, Ruff, Biome, shellcheck, shfmt land in the full shell.

## Activation

- `nixos-rebuild switch` brings up `direnv` + `nix-direnv` for `pvl`.
- `direnv allow` at repo root (and in each child dir as needed) loads the flake
  env.
- VS Code reload picks up `mkhl.direnv`; `nix-env-selector` is gone.
