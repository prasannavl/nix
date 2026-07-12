# Abird Latest Post-4469 Port 2026-07

Audit window: `446992e9..abird/master`, where `abird/master` was `a70ec656` on
2026-07-12.

Per-commit ledger:

- `babff9c4 fix(opendesign): build image from source`: skipped.
  `pkgs/ext/opendesign`, `pkgs/manifest.nix`, `hosts/abird-corp`, and the
  OpenDesign note are Abird-only in this checkout. Local grep found no
  OpenDesign service/package usage to port.
- `1d4b2b48 fix(podman-compose): harden compose starts`: adopted for shared
  `lib/podman-compose`. The code/test files are byte-identical to
  `abird/master`; local docs were adapted to the generic image-present
  pre-activation invariant and the renamed `composeUpNoProgressSeconds` option.
  The Abird `graphiti` callsite and Abird-only Tic-Tac-Toe incident detail were
  skipped.
- `36c3fb13 feat(host-manager): add host operations`: adopted with local stack
  adaptation. The shared host-operation surface, SSH inventory routing, remote
  cleanup/log/service scripts, positional host parsing, runtime `openssh`
  dependency, and tests were ported. Abird's default `abird` service stack,
  `abird-gondor`/stage/dev host mapping, fallback unit prefix/user, and
  generated Incus profile paths were replaced with this repo's `pvl` stack and
  `machineProfiles.incusLxc` scaffold.
- `d8f59097 style(docs): format notes`: skipped as a standalone port. Only the
  relevant local docs were updated and formatted.
- `a70ec656 style(host-manager): format script`: adopted as part of the
  host-manager operations port.

Parity audit:

- Byte-identical to `abird/master`:
  - `lib/podman-compose/default.nix`
  - `lib/podman-compose/helper.sh`
  - `lib/podman-compose/tests/module.nix`
  - `lib/podman-compose/tests/test_helper.py`
- Intentionally adapted:
  - `pkgs/tools/host-manager/host-manager.sh`
  - `pkgs/tools/host-manager/tests/test_host_manager.py`
  - `.agents/docs/notes/tooling/host-manager-operations-2026-07.md`
  - `.agents/docs/README.md`
  - `docs/podman-compose.md`
  - `.agents/docs/notes/services/podman-compose-pull-source-sidecars-2026-07.md`
- Skipped Abird-only paths:
  - `pkgs/ext/opendesign/default.nix`
  - `hosts/abird-corp/services/opendesign.nix`
  - `hosts/abird-data/services/graphiti/default.nix`
  - `.agents/docs/notes/apps/opendesign-image-source-2026-07.md`

Validation:

```bash
bash -n lib/podman-compose/helper.sh pkgs/tools/host-manager/host-manager.sh
python lib/podman-compose/tests/test_helper.py
python pkgs/tools/host-manager/tests/test_host_manager.py
nix build --no-link .#checks.x86_64-linux.lib-podman-compose-helper
nix build --no-link .#checks.x86_64-linux.lib-podman-compose-module
nix build --no-link .#host-manager
git diff --check
git diff --exit-code abird/master -- lib/podman-compose/default.nix lib/podman-compose/helper.sh lib/podman-compose/tests/module.nix lib/podman-compose/tests/test_helper.py
```
