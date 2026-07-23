# Nixbot Signed Build Cache Design

Date: 2026-06-12

## Purpose

This note is the handoff plan for replacing `nixbot` deploy-host remote
activation with a signed build-host binary cache model.

The intended direction is removal, not deprecation:

- remove non-local `--deploy-host`;
- remove hidden `remote-activate`;
- keep `--build-host` as the build placement knob;
- make build hosts publish signed cache artifacts;
- keep activation, rollback, parent readiness, and health checks owned by the
  local `nixbot` orchestrator.

## Target Design

`nixbot` has one activation authority: the local orchestrator process.

Remote build hosts are only builders and cache publishers. They do not run
`nixbot`, do not activate targets, and do not own deploy orchestration.

Final flow:

```text
operator nixbot
  -> build closure on build-host via ssh-ng://build-host
  -> ensure closure is signed and available from build-host cache
  -> snapshot target from operator side
  -> prepare target SSH from operator side
  -> target pulls closure from trusted cache
  -> target runs switch-to-configuration
  -> operator runs health checks / rollback logic
```

## Phase 1: Remove Remote Activation Surface

In both repos:

- Remove `--deploy-host` from CLI usage, parsing, env handling, completion, and
  validation.
- Remove `remote-activate` as a public/internal action.
- Remove `REMOTE_ACTIVATE_SYSTEM_PATH`.
- Remove `run_remote_activate_action`, `remote_activate_host`, and
  `run_deploy_on_remote_host`.
- Remove deploy-phase branch:

```bash
if [ "${DEPLOY_HOST}" != "local" ]; then ...
```

- Remove docs that describe `--deploy-host`, remote activation, deploy-host
  command path, and hidden remote nixbot execution.
- Keep `--build-host`; that remains the build placement knob.

Current unstaged remote-activation fixes in both main worktrees become obsolete
under this plan and should be replaced by the removal.

## Phase 2: Keep Remote Build, Change Transport Model

Keep the useful part:

```bash
nix build --store ssh-ng://<build-host> ...
```

Keep or adapt the remote-store retry helper, because build-host SSH can still
fail transiently.

Change what happens after remote build.

Current local-copy-back behavior:

```text
nix copy --from ssh-ng://build-host <out-path>
```

Target behavior:

```text
builder signs closure
target pulls closure from builder cache
operator never imports the closure locally unless action is build-only/dev-build
```

For `deploy` with non-local `--build-host`, local nixbot only needs the out path
string and a guarantee that the path is signed and cache-visible.

## Builder Identities

There are two intended builder signing identities in the fleet:

- `abird`
- `pvl`

The pvl repo should stay agnostic to the concrete peer builder host identity. It
should model the pvl-owned builder concretely as `pvl-x2`, publish artifacts
signed by the logical `pvl` key, and trust the peer logical `abird` key for
artifacts produced outside this repo.

In other words, pvl may know:

- local builder host: `pvl-x2`;
- local signing identity: `pvl`;
- peer trusted signing identity: `abird`.

It should not need to know which concrete host currently produces artifacts for
the peer `abird` key.

## Phase 3: Builder Signing Contract

Add repo-local nixbot defaults and keep the build host itself as an ordinary
`hosts/nixbot.nix` host record:

```nix
globals = {
  ci = {
    host = "pvl-x2";
  };
  buildCache = {
    host = "pvl-x2";
    url = "http://pvl-x2:5000";
  };
  repoUrl = "ssh://git@github.com/prasannavl/nix.git";
};

hosts = {
  pvl-x2 = {
    target = "pvl-x2";
  };
};
```

The cache endpoint is local to the repo's own build host. It must not point at a
peer repo's cache. `globals.buildCache.url` is the target/operator-facing cache
URL, and `globals.buildCache.host` is the host identity that owns that URL for
`--build-host-deploy-mode auto`. Keep the cache URL separate from SSH inventory
overrides so cache verification and target-side cache copies use the published
cache endpoint.

Do not reuse SSH, TLS, or CA keys. Use a dedicated Nix signing key.

Builder host config needs:

```nix
nix.settings.secret-key-files = [ "/run/secrets/nix-builder-signing-key" ];
services.harmonia = {
  enable = true;
  signKeyPaths = [ "/run/secrets/nix-builder-signing-key" ];
  settings.bind = "0.0.0.0:5000";
};
```

All consumers need:

```nix
nix.settings.substituters = [
  "http://pvl-x2:5000"
  ...
];
nix.settings.trusted-public-keys = [
  "pvl:..."
  "abird:..."
  ...
];
```

The build-host cache service is Harmonia, not `nix-serve`. `nix-serve` produced
intermittent malformed HTTP replies under deploy-time cache requests; Harmonia
keeps the same signed `/nix/store` cache model and port while moving the cache
server to the maintained NixOS module and Rust implementation.

## Phase 4: Builder-Side Signing

After:

```bash
nix build --store ssh-ng://pvl-x2 --print-out-paths --no-link ...
```

the builder's Nix daemon signs locally built paths through
`nix.settings.secret-key-files`. `nixbot` must not SSH to the builder to run
`nix store sign`; signing is builder host configuration, not orchestrator
behavior.

Important details:

- Signing happens on the build host through normal Nix local-build behavior.
- It fails hard when the builder lacks the configured signing key or the cache
  cannot serve signed narinfo data.
- For local builds, skip signing unless local cache publishing is configured.

Then verify cache availability before deploy:

```bash
nix path-info --store <cache-url> <out-path>
```

or an equivalent narinfo check.

## Phase 5: Target Pull Before Activation

Before activation, local nixbot should make the target fetch the exact path:

```bash
nix copy --from <builder-cache-url> <out-path>
```

executed on the target through the already prepared target SSH context.

Then activate exact path:

```bash
<out-path>/bin/switch-to-configuration switch
```

This preserves the strong property from remote activation: activate exactly the
closure that was built. It just moves artifact transfer to the target instead of
the operator.

## Phase 6: Fallback Policy

Be strict initially:

- If `--build-host local`, existing local deploy path remains.
- If `--build-host <remote>` and action is `deploy`, require a configured cache
  for that build host.
- Do not silently copy back to local for deploy, because that hides
  misconfigured cache trust.
- For `build` or `dev-build`, copy-back/result-link behavior can remain if
  useful, since no target activation is involved.

## Phase 7: Docs Cleanup

In z:

- Remove or rewrite
  `.agents/docs/notes/nixbot/deploy-host-remote-activation-plan-2026-06.md`.
- Update `.agents/docs/README.md` if the file is deleted.
- Update `.agents/docs/notes/nixbot/deploy-system-consolidated-2026-03.md`.

In pvl:

- Remove or rewrite
  `.agents/docs/notes/hosts/nixbot-deploy-host-command-2026-06.md`.
- Update `.agents/docs/README.md` if deleted.
- Update `.agents/docs/notes/nixbot/deploy-system.md`.

The durable note should say: build hosts publish signed cache artifacts;
activation remains local-orchestrated.

## Pvl Implementation Status

Implemented in the pvl repo:

- `--deploy-host`, `NIXBOT_DEPLOY_HOST`, hidden `remote-activate`, and
  `--system-path` were removed from `pkgs/tools/nixbot/nixbot.sh` and Bash
  completion.
- `hosts/nixbot.nix` now declares `globals.ci.host = "pvl-x2"`,
  `globals.buildCache.host = "pvl-x2"`,
  `globals.buildCache.url = "http://pvl-x2:5000"`, and the managed `repoUrl`.
  The pvl builder URL is explicit so cache verification does not follow local
  SSH transport overrides.
- `pvl-x2` owns signing and cache publishing through
  `nix.settings.secret-key-files` and `services.harmonia`.
- The pvl builder signing key is generated under
  `data/secrets/globals/nix/builder-pvl.key.age`, with public key material at
  `data/secrets/globals/nix/builder-pvl.pub`.
- The peer Abird public key material is recorded at
  `data/secrets/globals/nix/builder-abird.pub`; this repo does not own the
  private Abird signing key.
- `lib/nix.nix` configures all hosts to use the local pvl cache URL
  `http://pvl-x2:5000` and to trust both the `pvl-1` and `abird-1` public
  signing keys. The pvl repo intentionally does not configure the peer Abird
  cache URL.
- Deploy actions with non-local `--build-host` now require a configured builder
  cache, verify cache visibility from the local orchestrator, make the target
  pull the exact path from the builder cache, and activate that exact path
  locally over the prepared target SSH context.
- Target-side cache copies pass the target's declared Nix public trust keys as
  temporary `nix --option extra-trusted-public-keys ... copy` options. This lets
  the first rollout of cache trust use the signed builder cache before the
  target has activated the new Nix daemon trust config. The `local-copy` relay
  path uses the same temporary target trust bridge while still sourcing the
  deployed closure from the signed build-host cache.
- Remote builds keep `--build-jobs` concurrency. If a remote Nix daemon drops a
  store connection under load and Nix reports
  `Nix daemon disconnected
  unexpectedly`, nixbot treats that as a retryable
  remote-store transport failure rather than a deterministic evaluation error.
- Failed, interrupted, and hung-up runs retain only the diagnostic-safe `diag-*`
  tree under `/var/tmp/nixbot`; the disposable `run-*` tree is always removed.
  Build result symlinks, decrypted secrets, SSH state, and Terraform plans stay
  in `run-*`, along with build `.path` files, rollback snapshots, and phase
  artifacts. Logs, statuses, and stderr captures stay in `diag-*`.
- Parallel remote builds prewarm the build-host SSH ControlMaster before fanout,
  so concurrent host builds reuse the same socket instead of racing to create
  it.
- Remote builds pass `--eval-store auto` with `--store ssh-ng://<build-host>` so
  flake evaluation stays on the workstation while realization happens on the
  build host. Without that split, Nix can materialize evaluation inputs through
  the remote store and make the build host look idle before derivations start.
- Remote deploy builds default to `--build-host-deploy-mode auto`: use `cache`
  when `--build-host` resolves to the configured `globals.buildCache.host`;
  otherwise use `local-copy`. `cache` verifies the build-host cache, makes the
  target copy the exact path from that cache, then activates it. `local-copy`
  verifies the same signed cache path, then relays it from the build-host cache
  to the target with the local client and the same temporary target trust-key
  bridge. Deploy local-copy mode intentionally avoids raw `ssh-ng://` copy-back
  into the operator store. Build-only copy-back uses the signed build-host cache
  when it is configured, and falls back to raw `ssh-ng://` only when there is no
  cache. Use `local-copy` when the operator can reach both sides but the target
  cannot reach the build-host cache.
- Remote deploy build-cache validation fails before activation when
  `globals.buildCache.url` or `globals.buildCache.host` is missing, or when the
  selected `--build-host` does not match the configured cache owner. The
  diagnostic should name the build host, configured cache URL, configured cache
  host, and the expected `--build-cache-host`/`--build-host` correction instead
  of a generic missing-config message.
- Only the `nixbot` account is added as a trusted Nix user. Direct runs from an
  untrusted operator account can still warn that the client-specified `store`
  setting is restricted; avoid broad trust expansion and run through `nixbot`
  when the warning must be eliminated.
- Remote build heartbeat workers close stdout and write status only to stderr.
  This matters because nixbot captures remote build stdout with command
  substitution; a heartbeat that inherits stdout can keep the capture pipe open
  after Nix exits, producing a false long-running build with no remote load.
- Build-only remote builds still copy the closure back for local result
  handling. They use the signed build-host cache when it is configured, and fall
  back to raw `ssh-ng://` only when there is no cache.
- The superseded pvl note
  `.agents/docs/notes/hosts/nixbot-deploy-host-command-2026-06.md` was deleted;
  `docs/deployment.md` and `.agents/docs/notes/nixbot/deploy-system.md` were
  rewritten around signed cache publishing and local-orchestrated activation.

2026-06-12 validation:

- `pvl-x2` serves `nix-cache-info` and signed narinfo responses at
  `http://192.168.1.1:5000`.
- A deploy using `--build-host=pvl-x2` failed when cache verification used
  `http://pvl-x2:5000` because that name resolved to an unreachable tailnet
  route while the build-host override used `192.168.1.1`.
- The clean nixbot fix is to derive the local builder cache URL from the
  existing build-host inventory record after overrides, not to add peer cache
  URLs or a separate builder namespace.
- A follow-up target-side `nix copy` failed because the path lacked a signature
  by a trusted key, even though the narinfo was signed by `pvl-1`; that was the
  first-rollout trust gap on the target, not an unsigned old cache entry. The
  copy path now supplies the target's declared trust keys for that one command.

Remaining fleet work:

- Deploy the global cache trust settings to targets before relying on remote
  builds for live deploys.

## Phase 8: Validation Plan

Static:

```bash
bash -n pkgs/tools/nixbot/nixbot.sh
shellcheck pkgs/tools/nixbot/nixbot.sh
git diff --check
deno fmt <changed docs>
```

CLI negative tests:

```bash
./scripts/nixbot.sh --help
./scripts/nixbot.sh deploy --deploy-host=build-host ...
# should fail: unknown option
./scripts/nixbot.sh remote-activate ...
# should fail: unknown subcommand
```

Dry deploy shape:

```bash
./scripts/nixbot.sh deploy --host=<target> --build-host=pvl-x2 --dry
```

Expected dry shape:

```text
remote build on pvl-x2
verify pvl-x2 cache through rendered local builder URL
target copy from rendered local builder URL
target activate exact path
```

Live rollout later:

1. Deploy trust/cache config to builder and one low-risk target.
2. Build one target on builder.
3. Verify target can pull path from cache manually.
4. Run `nixbot deploy --host=<one target> --build-host=pvl-x2 --no-rollback`
   only after manual cache pull works.
5. Expand to parented guests after parent/target cache reachability is
   confirmed.

## Recommendation

This is cleaner than `--deploy-host` because it aligns with Nix's trust model:

- build placement: builder;
- artifact distribution: signed binary cache;
- activation authority: local nixbot over target SSH;
- rollback and health checks: local nixbot.

Implement this by first removing remote activation entirely, then adding the
cache/signing path as a separate logical change. That gives a clean diff
boundary and avoids carrying dead deploy-host complexity while designing the
cache path.

## Handoff Notes

- The main worktrees currently contain unstaged `deploy-host`/`remote-activate`
  fixes from the earlier investigation. Treat those as temporary debugging
  fallout, not the desired end state. The implementation pass should replace
  them with the removal described above.
- Keep the remote-store retry helper if it is still useful for
  `nix build --store ssh-ng://<build-host>`. It solves build-host transport
  retries and is independent of remote activation.
- Do not let the build host become a second deploy controller. If a target is
  not reachable from the operator, fix target routing, proxying, or inventory
  transport explicitly in `hosts/nixbot.nix`.
- Cache reachability becomes a deploy precondition. A target that cannot reach
  the builder cache should fail before activation.
- Signing key material belongs only on approved builder/cache hosts. Managed
  targets should receive only public trust keys and substituter URLs.
- In pvl, keep the peer concrete builder host and cache URL out of the durable
  builder contract. Trust peer artifacts through the logical `abird` public key
  only; do not configure the peer Abird cache URL here.
- Roll out cache trust before relying on remote builds for deploy. First prove
  that one target can fetch a known signed closure from the builder cache.
