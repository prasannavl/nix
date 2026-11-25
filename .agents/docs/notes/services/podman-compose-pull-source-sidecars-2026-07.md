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

`ab/runtime/podman/nixos.nix` gives Acquire a store-backed project with the same
first-entry directory name, declared dotenv, and sidecars as startup. The
packaged adapter resolves the stock provider model; it does not invoke project
`pull`. Podman acquires missing remote references in the owner's store. A stamp
is not evidence that an image still exists.

For `pvl-immich`, the candidate directory must include `compose.yml`, `.env`,
`hwaccel.ml.yml`, and `hwaccel.transcoding.yml`. Both `extends` and the four
remote image requirements must resolve without staging files under
`/var/lib/pvl/compose/immich` or fetching images. Use the same provider-resolved
names, profiles, and entry directory to supervise the live project.

The adapter checks the stock provider's expanded file list and active
`extends.file` paths against the immutable project directory. A declared live
absolute path is still a live path: use a relative reference to its candidate
copy. Teardown compatibility is tied to the launching systemd invocation, not
the current `/etc` helper or an image-acquisition stamp.

```sh
nix build --no-link .#checks.x86_64-linux.lib-podman-compose-helper \
  .#checks.x86_64-linux.lib-podman-compose-module \
  .#checks.x86_64-linux.lib-podman-compose-quadlet-conversion
nix build --no-link --print-out-paths \
  .#nixosConfigurations.pvl-x2.config.system.build.podmanComposeImagePullPlan
```
