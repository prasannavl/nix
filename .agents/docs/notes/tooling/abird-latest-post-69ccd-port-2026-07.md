# Abird Latest Post-69CCD Port 2026-07

Audit window: `69ccd060..abird/master`, where `abird/master` was `53a66371` on
2026-07-13.

Per-commit ledger:

- `74c9fd87 fix(excalidash): stabilize backend recovery`: skipped. The change is
  Abird host topology in `hosts/abird-corp/services/excalidash.nix` plus an
  Abird host incident note. Static compose IPs and stale Prisma lock recovery
  are useful concepts, but there is no local Excalidash service consumer.
- `72a249a3 fix(podman-compose): retain local image tars`: adopted
  byte-identically in shared Podman Compose code and tests. Local docs were
  adapted to describe context preservation and the generated local-image closure
  root without copying Abird OpenDesign incident notes.
- `9a051c9f feat(excalidash): add migration helper`: deferred. The helper under
  `lib/services/excalidash` is the only potentially reusable Excalidash unit,
  but this checkout has no local Excalidash package, stack entry, or service
  consumer. Its raw shell defaults are also Abird-specific, so adding it now
  would create unused shared code.
- `53a66371 fix(excalidash): split migrations from backend`: skipped. The design
  is correct for Abird, but the landed code wires the helper into `abird-corp`,
  uses Abird service paths, and adds `podmanSubnet` to the Abird registry.

Parity audit:

- Byte-identical to `abird/master`:
  - `lib/podman-compose/default.nix`
  - `lib/podman-compose/tests/module.nix`
- Intentionally adapted:
  - `docs/podman-compose.md`
  - `.agents/docs/design-patterns/podman-compose-instance.md`
  - `.agents/docs/notes/services/podman-compose-ready-repair-2026-07.md`
- Skipped or deferred:
  - `.agents/docs/notes/apps/opendesign-image-source-2026-07.md`
  - `.agents/docs/notes/hosts/abird-corp-excalidash-2026-05.md`
  - `hosts/abird-corp/services/excalidash.nix`
  - `lib/services/excalidash/default.nix`
  - `lib/services/excalidash/helper.sh`
  - `lib/stacks/abird-registry.nix`

Validation:

```bash
alejandra lib/podman-compose/default.nix lib/podman-compose/tests/module.nix
deno fmt docs/podman-compose.md .agents/docs/design-patterns/podman-compose-instance.md .agents/docs/notes/services/podman-compose-ready-repair-2026-07.md .agents/docs/notes/tooling/abird-latest-post-69ccd-port-2026-07.md .agents/docs/README.md
bash -n lib/podman-compose/helper.sh
python -m unittest discover --start-directory lib/podman-compose/tests --pattern 'test_*.py'
nix build --no-link .#checks.x86_64-linux.lib-podman-compose-helper .#checks.x86_64-linux.lib-podman-compose-module
git diff --check
git diff --exit-code abird/master -- lib/podman-compose/default.nix lib/podman-compose/tests/module.nix
```
