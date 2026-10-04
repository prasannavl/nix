# OpenDesign Node.js Output Checks 2026-10

## Context

`abird-host-manager fleet build` failed on `pvl-x2` while building the
OpenDesign container image:

```text
error: derivation '/nix/store/wgipqnr5aqcfbxh0jwvb0q1zhdjj54gn-nodejs-slim-24.18.0.drv'
       output check for 'libv8' contains output name 'out', but this is not a
       valid output of this derivation.
       (Valid outputs are [corepack, dev, libv8, npm].)
```

The failure was deterministic across repeated `fleet build` runs and blocked the
whole fleet (every host builds through `pvl-x2`).

## Root cause

Two facts combine:

1. `nixpkgs` `nodejs-slim` uses `__structuredAttrs = true` with cross-output
   `outputChecks`, for example
   `libv8.disallowedReferences = [ "out" "npm" ... ]`.
2. Nix 2.34 resolves those symbolic output names against only the outputs it
   realizes in the current build (`infos`), not against all derivation outputs.
   In `src/libstore/build/derivation-check.cc`, `checkRefs` looks up `outputs`
   (built this run) and throws when a referenced output name is absent.

When the builder store holds a partial output set, Nix skips the already-valid
outputs and rebuilds only the missing ones. The check then fails because the
already-valid output is not in the current-run set.

On `pvl-x2` the pinned, out-of-cache `nodejs-slim-24.18.0` had only `out` valid:

```text
yyvsyz78...-nodejs-slim-24.18.0           VALID   (ultimate, signed pvl-1)
crwbzp1r...-nodejs-slim-24.18.0-corepack  missing
cn19s1vs...-nodejs-slim-24.18.0-dev       missing
33r9mrvr...-nodejs-slim-24.18.0-libv8     missing
rm6i1kz6...-nodejs-slim-24.18.0-npm       missing
```

The partial set comes from the builder store's GC/retention: the lone `out`
survived while the other outputs were collected. Because `pvl-x2` builds
`nodejs-slim` (all outputs are produced whenever the derivation is realized),
every retry hit the same `libv8` check against the still-valid `out`.

Minimal reproduction (any Nix 2.34 host):

```nix
pkgs.stdenv.mkDerivation {
  pname = "outcheck-demo";
  version = "1";
  __structuredAttrs = true;
  outputs = ["out" "extra"];
  outputChecks.extra.disallowedReferences = ["out"];
  dontUnpack = true;
  buildCommand = "mkdir -p $out $extra; echo x > $out/m; echo y > $extra/m";
}
```

Build it, delete only `extra`, then build `^extra` while `out` is still valid:

```text
error: ... output check for 'extra' contains output name 'out', but this is not
       a valid output of this derivation. (Valid outputs are [extra].)
```

This is a Nix limitation, not a Nixpkgs or OpenDesign derivation bug. The same
shape can affect any multi-output derivation with cross-output `outputChecks`
when the builder holds a strict partial output set.

## Custom Node pin still required (2026-10-04)

The OpenDesign runtime still needs the pinned Node 24.18.0. The pin exists for
the `node::ObjectWrap` cleanup-hook regression, and that regression is unfixed
in the newest Node 24.x available through nixpkgs:

- Regression introduced by `nodejs/node#63642`
  (`src: add cleanup hooks to
  node::ObjectWrap`, commit `4b5eb7b72d`), first
  shipped in **24.19.0** (2026-08-03). `~ObjectWrap()` now calls
  `RemoveEnvironmentCleanupHook()` during GC, when no `Environment` is
  associated with the isolate, and aborts with
  `Assertion failed: (env) != nullptr`.
- Upstream issue `nodejs/node#65446` is still open (created 2026-08-20). The
  v24.x backport of the fix, `nodejs/node#65943`, is closed unmerged; the fix
  PRs are `nodejs/node#63985` and `nodejs/node#65630`.
- `nixpkgs` stable and unstable both ship **24.21.0** (2026-09-08), and there is
  no newer 24.x release. `src/node_object_wrap.h` at tag `v24.21.0` still calls
  the unguarded
  `RemoveEnvironmentCleanupHook(v8::Isolate::GetCurrent(),
  ...)`.
- OpenDesign 0.23.0 uses `better-sqlite3@12.10.0`, which subclasses
  `node::ObjectWrap` (`Statement`, `Database`, `Backup`, `StatementIterator`)
  and is rebuilt from source against the pinned headers. Per
  `nodejs/node#65446`, the crash follows the headers an addon is compiled
  against, so shipping a 24.19.0-or-later runtime with matching headers
  re-introduces the abort.

Dropping the pin therefore re-introduces the crash. The OpenSSL CCM patch is
only needed because the runtime is pinned to 24.18.0; commit `1433cf9d`
(`nodejs/node#65542`) is already in 24.21.0. When upstream lands the
`ObjectWrap` fix in a 24.x release and nixpkgs adopts it, both the pin and the
CCM patch can be dropped, and this `outputChecks = {}` workaround becomes
unnecessary (stock `nodejs-slim` is fully cacheable and is not partially built
in practice).

## Decision

Disable the cross-output reference checks on the OpenDesign-pinned Node.js
runtime only, in `pkgs/ext/opendesign/default.nix`:

```nix
outputChecks = {};
```

Rationale:

- The pin is out-of-cache and local to this image, so it is the derivation most
  exposed to partial builder-store state.
- Disabling `outputChecks` changes the derivation hash, so the poisoned `out`
  never matches again and all outputs build and register together.
- It also makes future partial store state harmless: an empty `outputChecks`
  never resolves symbolic output names, so rebuilding missing outputs succeeds.
- The build script is untouched, so output contents are identical; only store
  paths change.

Tradeoff: this drops nixpkgs' output-reference discipline checks for this
runtime. Those checks only validate the unchanged upstream build script; they do
not change what is built. Prefer a real Nix fix if one lands.

## Alternatives considered

- Repair the builder store only (delete the stale `out`, or rebuild all
  outputs), no code change. Fixes the immediate failure but recurs after the
  next GC that retains a subset of outputs.
- Patch Nix `checkRefs` to resolve output names against `drv.outputs` rather
  than only the current run. This is the general fix, but it requires
  bootstrapping a patched Nix onto `pvl-x2` and maintaining an upstream patch.
- Enable `keep-outputs` on the builder. Keeps all outputs but is global and
  increases builder disk use.

## Validation

- Minimal Nix 2.34 reproduction fails with `outputChecks`, and the same
  derivation with `outputChecks = {}` rebuilds a deleted output while `out`
  stays valid.
- The OpenDesign image re-evaluates to a new derivation with neutralized checks:
  - old `nodejs-slim` drv:
    `wgipqnr5aqcfbxh0jwvb0q1zhdjj54gn-nodejs-slim-24.18.0.drv`
  - new `nodejs-slim` drv:
    `0g9pk6c8bdiv1yq6amd1ribhyn7clq8s-nodejs-slim-24.18.0.drv`
  - new `structuredAttrs.outputChecks`: all empty (`{corepack={};dev={};...}`)

## Follow-ups

- Re-run `nix run .#abird-host-manager -- fleet build`; all `nodejs-slim`
  outputs build fresh under the new derivation hash.
- If this shape appears for another out-of-cache multi-output package, prefer
  the Nix `checkRefs` patch over per-package `outputChecks = {}`.
