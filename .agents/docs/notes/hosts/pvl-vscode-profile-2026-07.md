# PVL VS Code profile and Remote SSH extensions

On 2026-07-24, `pvl-l5` had the full Home Manager extension set under
`/home/pvl/.vscode/extensions`, while the concurrent Remote SSH extension host
under `/home/pvl/.vscode-server/extensions` was empty. The connecting client was
`pvl-a1`.

VS Code treats desktop/client and Remote SSH extensions as separate
installations. The official
[Remote SSH documentation](https://code.visualstudio.com/docs/remote/ssh#_always-installed-extensions)
defines `remote.SSH.defaultExtensions` as the client-side setting for extensions
that should always be installed on SSH hosts.

Home Manager's `profiles.default.userSettings` option owns the complete
`settings.json` file, and this version has no mutable-settings mode. The live
file was otherwise a normal writable user file, so using `userSettings` for one
key would unnecessarily prevent durable Settings UI edits.

`users/pvl/vscode/default.nix` instead keeps one `extensions` derivation list as
the source of truth and packages a local contribution-only `pvl.profile`
extension:

- `programs.vscode.profiles.default.extensions` installs the immutable local
  desktop extensions plus `pvl.profile`.
- `pvl.profile` contributes `remote.SSH.defaultExtensions` as a default derived
  from each real extension's `vscodeExtUniqueId`.
- The profile also contributes 16 selected settings from the live writable
  `settings.json`: editor and workbench presentation, terminal behavior, Git
  worktree/autofetch behavior, and ChatGPT and Kilo preferences.
- The profile extension declares `extensionKind = [ "ui" ]`, keeping it on the
  connecting client.
- User and workspace settings can still override the contributed default, and
  Home Manager does not take ownership of the user's `settings.json`.
- The duplicate `ms-azuretools.vscode-containers` entry was removed.

The evaluated `pvl-a1` and `pvl-l5` profiles each contain the same 25 real
extension IDs plus the local profile extension. Its manifest contributes the 16
selected settings and those 25 real IDs as Remote SSH defaults. Because Remote
SSH reads this setting on the connecting client, deploy the updated profile to
`pvl-a1`; the next Remote SSH connection then provisions the corresponding VS
Code Server extensions on `pvl-l5`.

Validation:

```console
alejandra users/pvl/vscode/default.nix
nix-instantiate --parse users/pvl/vscode/default.nix
nix eval --impure --json --expr '<compare local extension IDs and helper manifest defaults>'
nix build --no-link --print-out-paths --impure --expr '<build pvl.profile>'
nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw
```
