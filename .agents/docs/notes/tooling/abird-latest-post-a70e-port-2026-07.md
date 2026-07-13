# Abird Latest Post-A70E Port 2026-07

Audit window: `a70ec656..abird/master`, where `abird/master` was `69ccd060` on
2026-07-13.

Per-commit ledger:

- `d56e8832 fix(host-manager): use effective ssh inventory`: adopted with local
  adaptation. Host-manager now reads the effective nixbot inventory, including
  sibling overrides, and builds temporary SSH config entries for inventory-owned
  routing. Abird stack names, host alias mapping, and generated LXC profile
  imports were replaced with the local `pvl` stack and `machineProfiles`
  scaffold.
- `9d100e39 fix(podman-compose): repair stale verify state`: adopted
  byte-identically in shared Podman Compose code and tests.
- `628a0a6e fix(podman-compose): repair ready verify`: adopted byte-identically
  in shared Podman Compose code and tests.
- `9cf2f29c fix(podman-compose): bound start fanout`: adopted byte-identically
  in shared Podman Compose code and tests.
- `c47c5fe2 refactor(nixbot): move remote cleanup`: adopted as a split tooling
  unit. Nixbot local cleanup and host-manager target cleanup were ported; docs
  were adapted to make host-manager the canonical target-host lock cleanup
  surface.
- `90b1abd8 fix(opendesign): materialize runtime deps`: skipped. The local repo
  has no OpenDesign package or service consumer, so adding it would introduce an
  unused Abird package.
- `342a8dc9 fix(podman-compose): gate starts by level`: adopted byte-identically
  in shared Podman Compose code and tests.
- `5e80f665 fix(nixbot): normalize healthcheck rows`: adopted byte-identically
  in shared nixbot code and tests.
- `e9b1c9b3 docs(obs): record SIGBUS diagnosis`: skipped as Abird-only
  operational evidence.
- `ba921945 style(nix): group test users`: adopted in the byte-identical Podman
  Compose module tests.
- `f35df12c refactor(nixbot): add operator SSH identity`: adopted
  byte-identically in nixbot, with local config adapted by removing checked-in
  bootstrap/operator defaults from `hosts/nixbot.nix`.
- `bef92457 fix(nixbot): verify activation state before rollback`: adopted
  byte-identically in nixbot.
- `8fb0da6f fix(nixbot): allow same-generation rollback`: adopted
  byte-identically in nixbot.
- `4fe1d8da fix(opendesign): hoist runtime peers`: skipped with the rest of the
  unused OpenDesign package slice.
- `c642faa3 fix(stalwart): let systemd own restarts`: skipped as Abird service
  topology.
- `304ce293 fix(host-manager): use operator SSH identity`: adopted with local
  host-manager adaptations and documented in the host-manager operations note.
- `737ca2ff fix(nixbot): require operator for bootstrap`: adopted
  byte-identically in nixbot; local operator identity is expected from
  `hosts/nixbot.override.nix` or CLI flags.
- `2eab131d feat(podman-compose): handle local images`: adopted byte-identically
  in shared Podman Compose code, tests, and the image report helper. Local
  service callsites were not rewritten in this pass.
- `64c2236a fix(services): use nix-local images`: skipped for Abird service
  callsites. The shared `localImages` support was adopted, but this repo did not
  have a matching local service migration in the audit window.
- `69ccd060 style(docs): format local image notes`: adopted only through the
  local docs updated for this port.

Parity audit:

- Byte-identical to `abird/master`:
  - `lib/podman-compose/default.nix`
  - `lib/podman-compose/helper.sh`
  - `lib/podman-compose/tests/fake_podman.py`
  - `lib/podman-compose/tests/module.nix`
  - `lib/podman-compose/tests/test_helper.py`
  - `scripts/support/report-podman-images.py`
  - `scripts/support/tests/test_report_podman_images.py`
  - `pkgs/tools/nixbot/nixbot.sh`
  - `pkgs/tools/nixbot/nixbot.bash`
  - `pkgs/tools/nixbot/tests/test_nixbot.py`
- Intentionally adapted:
  - `pkgs/tools/host-manager/host-manager.sh`
  - `pkgs/tools/host-manager/tests/test_host_manager.py`
  - `hosts/nixbot.nix`
  - `docs/deployment.md`
  - `docs/podman-compose.md`
  - `.agents/docs/design-patterns/podman-compose-instance.md`
  - `.agents/docs/notes/nixbot/deploy-system.md`
  - `.agents/docs/notes/tooling/host-manager-operations-2026-07.md`
  - `.agents/docs/playbooks/nixbot-deploy.md`
- Skipped Abird-only or absent local consumers:
  - `hosts/abird-corp/**`
  - `hosts/abird-id/**`
  - `pkgs/ext/opendesign/**`
  - Stalwart/OpenDesign/OBS incident notes
  - Abird service local-image callsites without local analogs
  - Rust Tic-Tac-Toe, per prior user correction

Validation:

```bash
bash -n lib/podman-compose/helper.sh pkgs/tools/host-manager/host-manager.sh pkgs/tools/nixbot/nixbot.sh pkgs/tools/nixbot/nixbot.bash
python -m unittest discover --start-directory lib/podman-compose/tests --pattern 'test_*.py'
python -m unittest scripts/support/tests/test_report_podman_images.py
python -m unittest discover --start-directory pkgs/tools/host-manager/tests --pattern 'test_*.py'
python -m unittest discover --start-directory pkgs/tools/nixbot/tests --pattern 'test_*.py'
nix build --no-link .#checks.x86_64-linux.lib-podman-compose-helper .#checks.x86_64-linux.lib-podman-compose-module
nix build --no-link .#host-manager .#nixbot
nix eval --json --file hosts/nixbot.nix
git diff --check
git diff --exit-code abird/master -- lib/podman-compose/default.nix lib/podman-compose/helper.sh lib/podman-compose/tests/fake_podman.py lib/podman-compose/tests/module.nix lib/podman-compose/tests/test_helper.py scripts/support/report-podman-images.py scripts/support/tests/test_report_podman_images.py pkgs/tools/nixbot/nixbot.sh pkgs/tools/nixbot/nixbot.bash pkgs/tools/nixbot/tests/test_nixbot.py
```
