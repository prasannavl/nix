# `pvl-x2` cold rebuild and builder throughput

## Incident

`nix run .#abird-host-manager -- fleet deploy --host=pvl-a1 --dirty-staged` sat
in `phase 1/5 · stage build` (builder `pvl-x2`) for well over the expected
wall-clock, printing long runs of `[build] <cargo-src/cargo-package-*>.drv`
lines. The observed target derivation was
`nf9nk83nivzbyzrvvdq60y6wf571xlws-nixos-system-pvl-a1-26.05.20261008.7c8764b.drv`.

Two questions were raised: is the binary cache unavailable, and why is `pvl-x2`
(32 cores, 62 GiB) barely utilized during the build?

## Cache is healthy; the closure is cold

The cache is _not_ the failure. Verified on `pvl-x2`:

- `harmonia` is `active`, bound at `0.0.0.0:5000`, and returns signed narinfo
  (`curl -s -o /dev/null -w '%{http_code}' http://pvl-x2:5000/<hash>.narinfo` →
  `200`, with `Sig: pvl-1:...`).
- `nix config show` on `pvl-x2` reports
  `substituters = https://cache.nixos.org http://pvl-x2:5000 https://nix-community.cachix.org https://numtide.cachix.org`
  and the matching `trusted-public-keys`.
- Egress works: `https://cache.nixos.org/nix-cache-info` → `200` in ~41 ms.
- `nix path-info --store https://cache.nixos.org <missing path>` exits `0` for
  sampled missing outputs (≈59/60 of a random sample are present upstream).

The rebuild is caused by the _staged_ `flake.lock` bump, which moves `nixpkgs_2`
`774debe7a0d1b496e35677ad955a1011c6ff74f3` (`…20261002`) →
`7c8764b7c7b09b34f632464276218ef9090eaa11` (`…20261008`) and seven further
inputs, plus staged `lib/ext/*/sources.nix` version bumps. Every downstream
derivation hash changes, so the shared cache — which only ever contains what
`pvl-x2` itself realized — cannot answer for the new revision. This is inherent
to a nixpkgs bump, not a cache outage.

Closure and work-shape for the failing host build:

- Drv closure: 27,233 derivations / 31,606 store outputs
  (`nix-store -qR <system.drv>` / `nix-store -q --outputs`).
- `nix build --dry-run` on `pvl-x2` reported on the order of 900–1000
  derivations that still had to be _built_; everything else was substitutable.
  Most cached-elsewhere nixpkgs outputs do substitute.

## Why the builder is idle

`pvl-x2` enables `services.nix-builder-gc-coordination`, which sets
`nix.settings.max-jobs` and `nix.settings.http-connections`
(`lib/services/nix-builder-gc-coordination/default.nix`), with `cores = 0`. That
is a deliberate bounded-admission policy (see
`.agents/docs/notes/hosts/nix-builder-gc-coordination-2026-09.md`). At the time
of this incident the role defaulted `max-jobs = 1` and `http-connections = 8`;
see Resolution.

Measured effect during this build:

- `/proc/loadavg` ≈ 3.9–4.0 on a 32-core host, i.e. roughly one core busy.
- Exactly one `nix build` client for the whole host (`ps` showed a single
  `/run/current-system/bin/nix build --print-out-paths --no-link --fallback
  <system.drv>^out`).
- Store build logs under `/nix/var/log/nix/drvs/**` were created at ~30–50 per
  minute (one every ~1.2–2 s), monotonically, with no concurrency — e.g. 123 in
  5 minutes, 571 in 15 minutes, and ~1,000 in ~35 minutes.
- Sampled build logs showed real, successful work, dominated by cheap
  fixed-output downloads: `cargo-src-unic-langid-impl` fetching
  `https://static.crates.io/crates/unic-langid-impl/0.9.6/download`, plus
  `cargo-package-*`, `.vsix`, `cuda*-source`, `cargo-workspace-source`,
  `claude-code`, `codex-wrapper`, `chatgpt`.

So the wall clock is set by _serial admission of ~1,000+ mostly network-bound
derivations_, not by CPU, disk, memory, or substituter availability.

`BuildArgs::for_concurrency` in the fleet manager only adds
`--option eval-cache false` when `--build-jobs > 1`; the manager never passes
`--max-jobs`, and `options.build_jobs` defaults to `1`. The builder's `nix.conf`
is therefore the only knob, and `--build-jobs` cannot raise it. That separation
is intentional: see Resolution.

## Local builds never reach the shared cache

`harmonia` serves `pvl-x2`'s own store and nothing uploads to it. No
`post-build-hook` is configured anywhere, and the native Rust manager has no
push-to-cache path (the legacy `pkgs/tools/nixbot/nixbot.sh` had
`nix copy --to <store_uri>`). Only derivations realized _on_ `pvl-x2` are ever
served, so local `nix run`/`nix build` work on `pvl-l5` is invisible to it.

Verified waste: the 40 `cargo-src-*` fixed-output derivations that `pvl-x2`
fetched from `static.crates.io` within a 40-minute window were **already
realized in `pvl-l5`'s local store (40/40)**. Crate tarballs are not on
`cache.nixos.org` either
(`3kd0yysfssrpd9wk3wr5dkvxj2gipsi9-cargo-src-i18n-config-0.4.8` → `404`), so
each builder must fetch them from crates.io unless the shared cache already
holds them. Of the 367 crate FODs needed by the workspace, 359 were already
present locally and none were on the shared cache.

## Validation sequence

Re-run these before blaming the cache:

```sh
# 1. cache reachable and signed?
ssh pvl-x2 'systemctl is-active harmonia; curl -s -o /dev/null -w "%{http_code}\n" http://pvl-x2:5000/nix-cache-info'
# 2. substituters + admission settings as the daemon sees them
ssh pvl-x2 'nix config show | grep -E "^(substituters|max-jobs|cores|http-connections)"'
# 3. is the target closure cold (how much must actually be built)?
ssh pvl-x2 'nix build --dry-run --no-link /nix/store/<system>.drv^out 2>&1 | head -1'
# 4. is the builder serialized?
ssh pvl-x2 'cat /proc/loadavg; find /nix/var/log/nix/drvs -name "*.bz2" -newermt "-5 minutes" | wc -l'
# 5. sample whether a "missing" path is actually substitutable upstream
curl -s -o /dev/null -w "%{http_code}\n" https://cache.nixos.org/<hash>.narinfo
```

Interpretation: (3) large and (4) high log count with load ≪ cores means the
build is cold and serialized, not that the cache is down.

## Resolution

Applied: the role now defaults `max-jobs = 16` and `http-connections = 16`
(still below Nix's substitute default of 25), and
`lib/tests/nix-builder-gc-coordination.nix` asserts both. `cores = 0` is
unchanged, consistent with the repository preference for upstream defaults;
watch load and memory on the first cold rebuild, since 16 admitted derivations
that each take the effective CPU set can oversubscribe a 32-core host. If that
shows up, bound it with `cores` (e.g. `cores = 2` gives ~`nproc` total build
lanes) rather than lowering admission again.

Rejected on purpose: mapping the fleet manager's `--build-jobs`/a new flag onto
the remote `--max-jobs`. Builder capacity is host policy, not caller policy;
letting a caller widen admission would let any operator claim more of the shared
builder than the host allows. Admission therefore remains fixed by `nix.conf` on
the builder host.

## Remaining options

1. Feed the shared cache from local builds —
   `nix copy --to ssh-ng://nixbot@pvl-x2` for already-realized paths, or a
   `post-build-hook` on `pvl-l5`; alternatively route workspace/Rust builds to
   `pvl-x2` so the cache accumulates them.
2. Treat a `flake.lock` nixpkgs bump as a cold ~27k-derivation rebuild and
   pre-warm it on `pvl-x2` (or CI) before the deploy window.
