# Pi npm Lockfile Repair

## Symptom

`./scripts/update.sh` reached `lib/ext/pi/update.sh` and aborted while updating
`pi-web` 0.9.3 -> 0.10.0:

```text
warning: 6 out of 981 packages (0.6%) are missing 'resolved' URLs ...
thread '<unnamed>' (46) panicked at src/parse/mod.rs:171:22:
non-git dependencies should have associated integrity
error: Cannot build '...-pi-web-0.10.0-npm-deps.drv'
...
Could not determine npmDepsHash for pi-web
```

The pi updater aborts before `install_sources`, so the whole top-level run stops
and no pi package is recorded.

## Root cause

`pi-web` 0.10.0's release `package-lock.json` has bundled nested
`@earendil-works/pi-coding-agent/node_modules/@earendil-works/*` entries with a
registry `resolved` URL but **no `integrity`**. `prefetch-npm-deps` panics on
registry deps without integrity (`src/parse/mod.rs:171`) — it does not honor
`inBundle`/bundling. Six `@tailwindcss/oxide-wasm32-wasi/node_modules/*` entries
also lack `resolved` and are dropped with a warning.

## Solution

Repair the lockfile only inside the npm-deps fetch, where a fixed-output
derivation still has sandbox network, and let the main derivation consume the
repaired lock from that output:

```nix
npmDeps = pkgs.fetchNpmDeps {
  name = "${pname}-${source.version}-npm-deps";
  inherit src;
  hash = source.npmDepsHash;
  fetcherVersion = 2;
  postPatch = ''
    cp ${releaseSource}/package-lock.json package-lock.json
    chmod u+w package-lock.json
    ${pkgs.lib.getExe pkgs.npm-lockfile-fix} package-lock.json
  '';
};
```

The main derivation then adopts the FOD's repaired lock offline instead of the
upstream lock:

```nix
postPatch = ''
  cp ${npmDeps}/package-lock.json package-lock.json
'';
dontNpmPrune = true;
```

Key findings that shaped this:

- `buildNpmPackage` passes `postPatch` to **both** the npm-deps FOD and the
  **main** derivation. The main derivation has no sandbox network, so a repair
  running there fails with `NameResolutionError`. The repair must live in the
  FOD only.
- The npm-deps FOD output contains the repaired `package-lock.json`, so the main
  derivation can copy it without any extra recorded hash.
- `npm prune` then fails (`ERR_INVALID_ARG_TYPE`) on the repaired bundled
  entries; `dontNpmPrune = true` is the nixpkgs-suggested escape hatch and is
  safe here (`dontNpmBuild = true`).
- `npm-lockfile-fix` is the tool nixpkgs itself points at. No new `sources.nix`
  field, no static patch, no vendored lockfile is needed.

## Adjacent fixes

Two latent pi-updater bugs surfaced once pi-web stopped aborting the suite:

- `lib/ext/pi/update.sh`: `src_hash` was declared unset and `set_source_record`
  wrote `srcHash` unconditionally. `pi-diff` has no `srcHash` (its `src` is
  built from the GitHub source), so `set -u` aborted. `src_hash` is now
  initialized and `srcHash` is written only when non-empty.
- `lib/ext/pi/pi-diff/default.nix`: `pi-diff` 0.9.2 added `peerDependencies` for
  the runtime-provided `@earendil-works` packages; the manifest reconciliation
  now strips them from `package.json` and the root lock entry too.

## Validation

- `lib/ext/pi/update.sh --package pi-web` builds and installs `pi-web` 0.10.0.
- Full `lib/ext/pi/update.sh` exits 0, installing `pi-subagents` 23.0.0,
  `pi-web` 0.10.0, `pi-diff` 0.9.2, and `pi-mcp-adapter` 5.0.0.
- `alejandra` and `bash -n` pass on the touched files.

## Source of truth files

- `lib/ext/pi/update.sh`
- `lib/ext/pi/pi-web/default.nix`
- `lib/ext/pi/pi-diff/default.nix`
- `lib/ext/pi/sources.nix`
