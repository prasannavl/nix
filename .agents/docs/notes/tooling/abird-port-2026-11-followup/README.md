# Abird forward port — November 2026 follow-up

Forward port of the Abird (`z`) work created after the previous shared port.
Status: integrated into `master` as seven signed logical commits. No push or
deployment.

## Boundaries

- Destination base: `7723150f513f6eb6ff6122d0cee042a9a85e2b91` (nix `master`).
- Source: Abird `master` `c735a7247`, window
  `070011e2923ebdb16370bbfbba31876c47584002..c735a7247` — 64 commits (20
  first-parent plus a 44-commit side branch merged at `df8941601`).
- Previous port froze `070011e2` and recorded the 452-commit ledger in
  [abird-port-2026-11](../abird-port-2026-11/README.md).
- Abird reverse-ported nix `7723150f` back as `3f52a57eb`
  (`Audit-Source: 7723150f…`). Commits carrying `Upstream-Commit:` therefore
  already exist here; they are `already-adopted`, not new work.
- Integrated series and final tree: see [verification](verification.md).

## Method

1. Enumerate all 64 commits; classify every changed path by destination presence
   and by ownership (shared library/package, Abird product, Abird plan/secret
   material).
2. Treat `Upstream-Commit:`/`Audit-Source:` trailers as provenance evidence and
   prove it by byte comparison of the touched paths, never by trailer alone.
3. For paths byte-identical to the previous frozen source, copy Abird `HEAD`
   verbatim. For paths the destination deliberately diverged, three-way merge
   and keep the destination's interface/topology.
4. Validate with canonical format/lint and focused derivations; no fleet or
   whole-system builds.

## Logical units

| Unit                        | Destination commit | Scope                                                |
| --------------------------- | ------------------ | ---------------------------------------------------- |
| Lint: native full checks    | `e1bf92a6f`        | `scripts/lint.sh`, drop the batching regression test |
| Lint: store-path pins       | `03bccfc2f`        | `scripts/lint.sh`                                    |
| AI consumer bindings        | `86093ab34`        | `lib/services/ai/consumer.nix` + tests               |
| Age identity selection      | `25ef20eb8`        | `lib/flake/service-module.nix`                       |
| Stalwart opentelemetry      | `0cd03cf02`        | `pkgs/ext/stalwart-server/*`                         |
| Cloudflare validation tests | `0a393d311`        | `tf/tests/*`, `lib/tests/default.nix` registration   |
| External-unit roots         | `12244f6d1`        | `pkgs/README.md`, `external-source-units.md`         |

## Dispositions

[commits.tsv](commits.tsv) lists all 64 source commits: 8 adopted (4 whole, 4
partial), 6 already adopted, 50 skipped.

- **Adopted.** Lint units, AI consumer library, age identity selection, Stalwart
  source patch, Cloudflare validation tests, external-unit root documentation.
- **Adopted partially.** The AI refactors also rewired `hosts/abird-*` services,
  and the lint unit also rewrote Abird's own `.agents` benchmark notes; neither
  has a destination counterpart. The Cloudflare commit re-applied the
  already-ported hardening to Abird's variable interfaces and added tests.
- **Already adopted.** `75d0f2c08`, `59657b847`, `b81e28f9d`, `efa3cd017`,
  `3f52a57eb`, `b29f43ebd` are reverse ports of nix `161587584`, `51e7fa088`,
  `78a47d653`, `15d6c7f49`, `48b56e1d`, `09e7dcb8`, `7b3e32e33`, `c56e067b9`,
  `de8266df2`, `438c7e3ed`, `61676d22e`, `878c1283`, `f4cefc13`, `b4497dbe`. All
  shared paths in them are byte/mode equal here.
- **Skipped.** 44 `pkgs/srv/abird-agent`, `pkgs/support/abird-protocol` and
  `pkgs/web/abird-web` context commits, the retired-backup runtime and its
  encrypted recovery secrets, the `pkgs/ext/codex-app-server` and queue tools,
  and Abird plan/work records. Private products, secrets and plan state are not
  shared surface.

## Deliberate divergence

- Cloudflare variables keep this repository's interfaces: `workers_*`,
  `secret_zones_*`, required non-null DNS `zones`, zone/tunnel topology and
  encrypted channels. Only Abird's tests were ported, adapted to those names.
- `CONTRIBUTING.md` keeps the public MIT contribution contract; Abird's
  private-monorepo licence text is not adopted.
- `pkgs/manifest.nix`, `overlays/default.nix` and the child-flake overlays keep
  local registration, Pvl overlays and workspace-policy injections.
- Abird notes for `agent-workspace-linux`/`tuicr` describe Abird's host state;
  this repository's notes already describe its own layout. Only the shared
  ownership rule moved.
- Full-scope lint evaluates the flake natively again. Abird measured its fleet
  at ~1.8 GiB peak sequential host evaluation; memory, not correctness, is the
  binding constraint for `--full`.

## Verification

[verification.md](verification.md): byte-equality proof, format/lint outcomes,
focused check realizations and explicit limits.

## Parity

[parity.md](parity.md): current shared-tree audit, per-tree counts and the
classified exception list.
