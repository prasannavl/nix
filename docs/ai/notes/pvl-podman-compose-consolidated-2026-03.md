# Podman Compose Module Consolidated Notes (2026-03)

## Scope

Consolidates the March 2026 `services.podmanCompose` work: the initial
`pvl-x2` compose migration, follow-on module cleanup, file materialization
fixes, OpenCloud support, and function-valued instance ergonomics.

## Final model

- `services.podmanCompose.<stack>.instances` is the canonical stack member name.
  The old `services` naming was removed.
- Stack-level path configuration uses `stackDir`, not `workingDir`.
- Instance definitions may be either a plain attrset or a function receiving:
  `{ stackName, instanceName, stackDir, workDir, user, uid, podmanSocket }`.
- `podmanSocket` is auto-derived from the stack user:
  `/run/podman/podman.sock` for `root`, otherwise
  `/run/user/<uid>/podman/podman.sock`.
- If `source` is set and `entryFile` is unset, `compose.yml` is treated as the
  default explicit entry file.
- `entryFile` may be a string or an ordered list of strings, so generated units
  can emit multiple `-f` arguments.

## File/materialization behavior

- Path-backed files are copied into dedicated store outputs before runtime
  linking. The module no longer relies on direct source-tree links that can
  dangle at service start.
- Path copying is binary-safe. Binary assets are copied with `cp`, not coerced
  through `readFile`.
- Path context is preserved by interpolating Nix paths directly in the copy
  script, avoiding sandbox failures caused by `toString`-based path stripping.
- `files` now handles:
  - text/string-rendered content
  - individual file paths
  - recursively expanded directory paths
- The temporary `extraFiles` split was removed.

## Host adoption

- `pvl-x2` compose stacks under `/home/pvl/srv/*` were translated into
  repo-managed definitions under `hosts/pvl-x2/compose/` and wired through
  `hosts/pvl-x2/services.nix`.
- Secret-bearing env/config inputs were intentionally sanitized to placeholders
  rather than copied from live host state.
- OpenCloud now uses one tree import:
  `files = { "" = ./compose/opencloud; };`
  plus an ordered multi-file `entryFile` list for compose layering.

## Net effect

- The module now supports repo-managed compose trees, binary assets, multi-file
  compose invocations, per-instance derived paths, and socket-aware templates
  without hand-written path boilerplate.

## Canonical interpretation

Treat this file as the canonical summary for the following superseded
March 2026 notes:

- `pvl-x2-srv-compose-translation-2026-03-02.md`
- `pvl-podman-compose-path-file-materialization-2026-03-03.md`
- `pvl-podman-compose-source-path-entryfile-default.md`
- `pvl-podman-compose-instances-and-manager-typo-2026-03-03.md`
- `pvl-opencloud-compose-file-list-via-module-option-2026-03-05.md`
- `pvl-podman-compose-extrafiles-recursive-paths-2026-03-05.md`
- `pvl-opencloud-single-tree-files-root-2026-03-05.md`
- `pvl-podman-compose-binary-path-materialization-2026-03-05.md`
- `pvl-podman-compose-path-context-preservation-2026-03-05.md`
- `pvl-podman-compose-instance-context-fn-2026-03-06.md`
- `pvl-podman-compose-stackdir-and-instance-workingdir-context-2026-03-06.md`
- `pvl-podman-compose-instance-context-workdir-shortname-2026-03-06.md`
- `pvl-podman-compose-derived-user-uid-socket-context-2026-03-06.md`
- `pvl-podman-compose-socket-context-naming-2026-03-06.md`
- `pvl-podman-compose-single-podman-socket-auto-resolution-2026-03-06.md`
