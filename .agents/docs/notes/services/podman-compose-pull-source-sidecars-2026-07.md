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

Validation used:

```sh
alejandra lib/podman-compose/default.nix lib/podman-compose/tests/module.nix
nix build --no-link .#checks.x86_64-linux.lib-podman-compose-module
nix build --no-link .#nixosConfigurations.pvl-x2.config.system.build.toplevel
nix build --no-link --print-out-paths \
  .#nixosConfigurations.pvl-x2.config.system.build.podmanComposeImagePullPlan
```

The generated `pvl-immich` metadata should show runtime `composeFiles` under
`/var/lib/pvl/compose/immich`, while `pullComposeFiles` points to
`/nix/store/*-podman-compose-pvl-immich-pull-sources/compose.yml` and that same
directory contains `hwaccel.ml.yml` and `hwaccel.transcoding.yml`.
