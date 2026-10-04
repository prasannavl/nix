# `pvl-a1` Obsidian Dock Icon Association

## Symptom

On the `pvl-a1` GNOME session (dash-to-panel at the bottom), the running
Obsidian window showed the generic Adwaita `application-x-executable` icon (the
blue gear) instead of the Obsidian icon, and it did not merge with the pinned
`obsidian.desktop` favorite.

## Root cause

GNOME Shell could not associate the running window with a desktop entry:

- Obsidian is Electron. Its `share/obsidian/app.asar` `package.json` declares
  `"desktopName": "md.obsidian.Obsidian.desktop"`, so the Wayland app-id (and
  the transient scope) is `md.obsidian.Obsidian`. Confirmed by the transient
  scope `app-md.obsidian.Obsidian-<pid>.scope` holding the process and by the
  running window rendering `application-x-executable`.
- The installed desktop entry was `obsidian.desktop` (`Exec=obsidian %u`,
  `Icon=obsidian`) with `StartupWMClass=md.Obsidian` — missing the `obsidian.`
  segment.
- GNOME matches a Wayland window by `meta_window_get_wm_class()` (= app-id)
  through `shell_app_system_lookup_desktop_wmclass`, which tries
  `md.obsidian.Obsidian.desktop` and then any desktop file whose
  `StartupWMClass` equals it (`g_desktop_app_info_get_startup_wm_class`).
  Neither matched, so the window became an anonymous app with the generic icon.

## Why a plain rebuild does not fix it

The nixpkgs fix renames the desktop file id and sets it to
`md.obsidian.Obsidian` (`startupWMClass = "md.obsidian.Obsidian"`). That fix is
present in `nixos-unstable` and `master`, but **not** in `nixos-26.05`.

The repo pins `pkgs` to `nixos-26.05` (flake input `nixpkgs` → lock node
`nixpkgs_2`, rev `774debe7`), whose `obsidian` still ships `obsidian.desktop`
with `startupWMClass = "md.Obsidian"`. Verified two ways:

- live branch check against `NixOS/nixpkgs` `nixos-26.05` still returns
  `startupWMClass = "md.Obsidian"`.
- `nix eval .#nixosConfigurations.pvl-a1.pkgs.obsidian.drvPath` returns the same
  derivation as the deployed system
  (`6g4wf9h74asmcf8llyq4skmqrj513y3n-obsidian-1.13.7.drv`), with
  `desktopItem = /nix/store/qcn64q2cbyva84sm44zh51vchhwy3mzg-obsidian.desktop`.

The 2026-10-04 lock refresh only moved `nixos-26.05` from `cf5e765` to
`774debe7`; both carry the bug. So deploying the current lock reproduces the
same desktop entry.

## Resolution options

Use the already-pinned fixed package, or patch the 26.05 entry:

- Pull `obsidian` from the existing `unstable` input, mirroring the
  `vscode`/`keyd` pattern in `overlays/unstable.nix`
  (`inherit (unstable) obsidian;`).
- Or keep the 26.05 build and rewrite only the desktop entry in an overlay
  (`prev.obsidian.overrideAttrs` with a `postInstall` that changes
  `StartupWMClass=md.Obsidian` to `StartupWMClass=md.obsidian.Obsidian`).

## Validation

- Pixel-matched the dock icon against Adwaita `application-x-executable.svg`; it
  is the generic fallback, not Obsidian.
- Read the transient scope `app-md.obsidian.Obsidian-194258.scope` from the
  process cgroup.
- Read `"desktopName": "md.obsidian.Obsidian.desktop"` from the installed
  `share/obsidian/app.asar`.
- Evaluated `pvl-a1.pkgs.obsidian` and confirmed the produced desktop item
  matches the deployed broken entry; confirmed `nixos-26.05` still ships
  `md.Obsidian` while `nixos-unstable`/`master` ship `md.obsidian.Obsidian`.
