# Abird Last-5 Native Compose Port, July 2026

## Scope

Reviewed the newest five commits on `abird/master` at `66b5046f`, starting from
local `master` at `7496fcef`.

The Abird remote had been force-updated since the prior local port tip
`88cd27bb`; the current branch diverged from that old tip at `1f968108`.

Goal: port relevant shared `lib/` and `pkgs/` behavior with byte-for-byte parity
where the same shared file can stay identical, adapt only local host/docs
surfaces, and explicitly record skipped Abird topology or docs-only units.

## Ported Logical Units

- Native Podman Compose user graph: `lib/podman-compose/{default.nix,helper.sh}`
  and tests now match Abird for generated
  stage/bootstrap/start/reconcile/verify/ready units, `<user>-managed.target`,
  `<user>-managed-ready.target`, local pull-policy overrides, control-registry
  export, and rootless idmap migration ordering.
- Service-module user-unit boundary: `lib/flake/service-module.nix` now matches
  Abird by adding `ConditionUser` to generated non-root user units and removing
  generic `services.systemd-user-manager` registration from the helper.
- Nixbot native compose support: `pkgs/tools/nixbot/**` now matches Abird for
  host-local action/activation locking, native managed-ready target discovery,
  Podman Compose control-registry health timeout budgets, and compatibility with
  legacy `systemd-user-manager` metadata.
- Root flake default profile: Abird's `machineProfiles.incusLxc` default was
  checked and intentionally skipped because it breaks local physical PVL hosts
  that rely on the `null` default unless a machine profile is explicitly set.
- Local Ollama model-pull adaptation: `pvl-x2`, `pvl-a1`, and `pvl-l5` keep
  model pulls as simple timer/manual user services outside
  `<user>-managed-ready.target`; restart triggers live on the native user
  service as string stamps, and the units no longer register with
  `systemd-user-manager`.

## Commit Ledger

- `1b12fdf4 style(docs): format deploy notes`: skipped. Standalone Abird docs
  formatting over Abird-owned docs paths; prior local July 10 note already
  recorded the equivalent skip.
- `1f968108 fix(stalwart): clarify recovery trap`: cleanly already ported.
  `lib/services/stalwart/helper.sh` was already byte-identical from the July 10
  port.
- `0ac1dc8f feat(podman-compose): use native user graph`: adopted. Shared Podman
  Compose module/helper/tests and `lib/flake/service-module.nix` were restored
  to byte parity. Abird host edits were skipped as files; local PVL Ollama
  model-pull units were adapted to the same native graph boundary.
- `2c619399 fix(nixbot): support native compose deploys`: adopted. Shared
  `pkgs/tools/nixbot/**` was restored to byte parity after the native graph
  landed locally. Legacy `systemd-user-manager` compatibility remains present
  because this repo still has direct non-compose users.
- `66b5046f docs: record native compose migration`: adapted. Abird-specific
  consolidated notes and plan were not copied. Local docs were updated in
  `docs/podman-compose.md`, `docs/systemd-user-manager.md`, and durable
  `.agents/docs/notes/**` endpoints that own the local service model.

## Byte-Parity Audit

The final shared target set should be byte-identical to `abird/master` for:

- `lib/flake/service-module.nix`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
- `lib/podman-compose/tests/fake_podman.py`
- `lib/podman-compose/tests/module.nix`
- `lib/podman-compose/tests/test_helper.py`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

Already-identical shared files that stayed unchanged include:

- `lib/podman-compose/image-pull-all.sh`
- `lib/services/stalwart/helper.sh`

Intentional non-parity remains for:

- `lib/flake/root.nix`, because this repo has PVL-specific flake inputs, keeps
  the physical-host-safe `machineProfile ? null` default, and still imports
  `../systemd-user-manager` for direct non-compose local units.
- Abird host modules, stack files, secrets, consolidated docs, and graph-plan
  files whose ownership is Abird-specific.
- Local PVL host Ollama modules and docs, which were adapted instead of copied.
