# Library Layout And Guardrails

## Scope

Canonical placement rules and review guardrails for shared helpers under `lib/`.

## Durable rules

- Keep flake-oriented helper code under `lib/flake/`.
- Keep standalone overlay or maintenance helper derivations under `lib/ext/`,
  not `pkgs/`.
- Keep service-specific shared modules under `lib/services/`.
- Keep shared pure flake helpers in one reusable library location instead of
  duplicating them across modules.

## Current placement decisions

- `duplicateValues` belongs with reusable flake-oriented helpers in
  `lib/flake/utils.nix`.
- Service-module relocation and similar support code should move toward the
  closest durable library namespace instead of staying as historical top-level
  paths.
- Direct repo references should use the canonical current library path after any
  move; do not preserve stale compatibility paths longer than necessary.

## Review guardrails

- Resume-time NetworkManager workarounds belong in
  `powerManagement.resumeCommands`, not in suspend-transaction systemd hacks.
- Optional guest Tailscale stays owned by `lib/incus-vm.nix`, not by the shared
  LXC base profile.
- Service scripts must declare every runtime tool they invoke.
- Incus-related shell assembly should use arrays and structured iteration, and
  dangerous cleanup paths should fail closed.
- `lib/services/kanidm` accepts `oauthApps` as either the historical attrset or
  an ordered list of entries. Use the list form when declaration order matters
  for generated provisioning state, while keeping attrset callers compatible.
- Kanidm OAuth app declarations may include `icon` and `ui` metadata. The
  service helper applies `icon` to Kanidm, while `pkgs/ext/kanidm-server` uses
  the generated metadata to sort/group the application links UI. Keep UI-only
  ordering/grouping data in that metadata instead of hard-coding it in the
  patched JavaScript.

## Source of truth files

- `lib/flake/**`
- `lib/ext/**`
- `lib/services/**`
- `lib/network-wifi.nix`
- `lib/profiles/lxc.nix`
- `lib/flatpak.nix`

## Provenance

- This note replaces the earlier dated library-layout, helper-relocation, and
  broader `lib/` review notes from March and April 2026.
