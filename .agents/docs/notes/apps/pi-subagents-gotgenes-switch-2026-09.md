# pi-subagents switched to @gotgenes/pi-subagents

On 2026-09-29 the Pvl Pi profiles replaced the unscoped `pi-subagents` package
(nicobailon/pi-subagents 0.71.0) with `@gotgenes/pi-subagents` 21.8.0 for the
`~/.pi/agent/extensions/pi-subagents` runtime extension.

## Why

The two packages have different execution models and different pi-web
interaction:

- `nicobailon/pi-subagents` spawns child Pi processes and exposes the `subagent`
  tool plus scripted `workflowScript`, missions, watchdog, external CLI agents,
  and remote machines.
- `@gotgenes/pi-subagents` runs children in-process (same Pi runtime) and
  exposes `subagent`, `get_subagent_result`, and `steer_subagent` with a typed
  `SubagentsService` and lifecycle events. Scheduling, cross-extension RPC,
  model-scope enforcement, and worktree isolation are deliberately out of its
  core.

The deciding factor was pi-web coexistence. Pi Web injects its own built-in
subagents (`Agent`, `get_subagent_result`, `steer_subagent`) and strips a
`pi-subagents`-sourced extension only when that extension registers one of those
same three tool names (`preferPiWebSubagentExtension` in `@agegr/pi-web`).
nicobailon's `subagent` never matched, so both toolsets loaded and the model had
to pick between overlapping tools. `@gotgenes/pi-subagents` keeps
`get_subagent_result`/`steer_subagent`, so pi-web now removes it whenever
`builtInEnabled` is true: the browser uses the built-in agents and the TUI uses
gotgenes.

## Packaging

`lib/ext/pi/pi-subagents/default.nix` now unpacks the published npm tarball with
`fetchzip` and copies it to `$out/lib/node_modules/@gotgenes/pi-subagents`. It
does not fetch npm dependencies:

- Pi's extension loader virtualizes the runtime imports an extension may make
  (`@earendil-works/*` and `@sinclair/typebox`, see the `VIRTUAL_MODULES` table
  in `@earendil-works/pi-coding-agent`), so the package's only declared
  dependency resolves from Pi itself.
- The package manifest points at `src/index.ts`, but Pi discovers a directory
  extension through a root `index.ts`/`index.js`. The derivation writes a thin
  `index.ts` re-export so the package's `#src/*` imports keep resolving from the
  package root.

`lib/ext/pi/sources.nix` records `package = "@gotgenes/pi-subagents"`, version,
and the unpacked tarball `srcHash`; `rev` and `npmDepsHash` are gone.
`lib/ext/pi/update.sh` now resolves `pi-subagents` through the npm tarball
branch instead of the GitHub-archive branch and no longer recomputes an
`npmDepsHash` for it.

This makes `.agents/docs/notes/apps/pi-subagents-npm-fetcher-v2-2026-09.md`
historical: the npm dependency fetch it fixed no longer exists for this package.

## Removed packaged resources

nicobailon/pi-subagents also shipped a `pi-subagents` skill, a `council-mode`
skill, and six prompt templates. `@gotgenes/pi-subagents` ships none of them, so
`users/pvl/pi/default.nix` no longer links:

- `~/.pi/agent/skills/pi-subagents`
- `~/.pi/agent/skills/council-mode`
- `~/.pi/agent/prompts/{council,gather-context-and-clarify,parallel-cleanup,parallel-research,parallel-review,review-loop}.md`

Those assets depended on nicobailon-only surfaces (`workflowScript`,
`subagent({ action: "list" })`, `runs.all`) and would not work against gotgenes.
Restoring an equivalent council flow, or vendoring an adapted `parallel-review`
prompt, is future work rather than part of this switch.

## Validation

- `nix build` of `lib/ext/pi/pi-subagents` (via the flake's `nixpkgs`) produced
  `/nix/store/...-pi-subagents-21.8.0` with `index.ts`, `src/`, and
  `package.json`.
- The Pi RPC-mode load smoke test exited 0 and emitted the extension's
  `setWidget` (`agents`) and `setStatus` (`subagents`) requests; a syntax-broken
  control extension failed with exit 1, confirming the harness surfaces load
  errors:

  ```console
  pi --mode rpc --no-extensions -e <pkg>/index.ts </dev/null
  ```

- `nix eval .#nixosConfigurations.pvl-l5.config.home-manager.users.pvl.home.file`
  shows the `pi-subagents` extension and no removed skill or prompt entries.
