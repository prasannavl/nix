# kilo-cli and kilo-code VS Code extension removed

Date: 2026-11-14

Drop kilo from the fleet config; pi is the AI coding tool in use.

Removed:

- `pkgs/tools/kilo-cli/default.nix` (prebuilt-wrapper package) and its
  `pkgs/manifest.nix` registration.
- `kilo-cli` from the `hosts/common/pvl.nix` AI package list.
- `kilocode.kilo-code` from the `users/pvl/vscode/default.nix` extension list,
  plus the three `kilo-code.new.*` profile settings.
- `.agents/docs/notes/tooling/kilo-cli-prebuilt-wrapper.md` (rationale for a
  package that no longer exists).

Kept: `/.kilocode/` and `.kilo/` in `.gitignore` — part of the shared Misc block
(tool state dirs), so leaving them keeps the cross-repo block byte-identical.

If kilo returns: the extension still ships a prebuilt `bin/kilo`
(`share/vscode/extensions/kilocode.kilo-code/bin`), which is the only working
route; the nixpkgs `unstable.kilo` source build fails in the sandbox.
