# Podman Compose Pull Source Sidecars 2026-07

On 2026-07-11, a `pvl-x2` deploy failed during the pre-activation
`podman-compose-image-pull-all` phase for `pvl-immich`:

```text
FileNotFoundError: [Errno 2] No such file or directory: '/nix/store/hwaccel.transcoding.yml'
```

The Immich compose source uses `extends.file: hwaccel.transcoding.yml`. Runtime
starts are safe because the helper stages `compose.yml` and the `hwaccel.*.yml`
files into `/var/lib/pvl/compose/immich` before running Compose. The deploy-time
image pull path is intentionally staging-free, so it used generated store
compose files directly. When the main generated compose file lived alone in the
store, podman-compose resolved the relative `extends.file` against `/nix/store`
and failed.

The shared fix belongs in `lib/podman-compose/default.nix`: generate a
store-backed pull-source directory for each compose instance containing every
effective staged file, then point `pullComposeFiles` at the entry file inside
that directory. Keep `composeFiles` pointed at runtime paths for normal
stage/start behavior.

The explicit `image-pull` command is a hard pre-activation gate. It must treat
final Podman pull error output as failure even when `podman compose pull` exits
successfully, then retry the full compose pull up to the configured attempt
budget before nixbot activation can continue. Normal start/reload pre-pulls
remain best-effort because `podman compose up` can still perform the
service-local pull under the managed start path.

Repeated deploy pulls should skip registry traffic only when the generated
`imagePullStamp` matches the helper runtime state and every declared image is
present in the local Podman image store. Treat helper state as the generation
marker, not as proof that images still exist locally.

Already-current deploy pulls should stay quiet. The batch
`podman-compose-image-pull-all` driver may use helper-provided status markers
for accounting, but it should not print one line per skipped service on normal
repeated deploys. Keep retry progress and actual pull/failure output visible.

Validation used:

```sh
alejandra lib/podman-compose/default.nix lib/podman-compose/tests/module.nix
deno fmt .agents/docs/README.md \
  .agents/docs/notes/services/podman-compose-pull-source-sidecars-2026-07.md
nix build --no-link .#checks.x86_64-linux.lib-podman-compose-module
nix build --no-link .#nixosConfigurations.pvl-x2.config.system.build.toplevel
nix build --no-link --print-out-paths \
  .#nixosConfigurations.pvl-x2.config.system.build.podmanComposeImagePullPlan
```

The generated `pvl-immich` metadata should show runtime `composeFiles` under
`/var/lib/pvl/compose/immich`, while `pullComposeFiles` points to
`/nix/store/*-podman-compose-pvl-immich-pull-sources/compose.yml` and that same
directory contains `hwaccel.ml.yml` and `hwaccel.transcoding.yml`.
