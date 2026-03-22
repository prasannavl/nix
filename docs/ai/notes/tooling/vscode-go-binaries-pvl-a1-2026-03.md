# VS Code Go Binaries On pvl-a1

## Context

- `users/pvl/vscode/default.nix` enabled the `golang.go` extension.
- `hosts/pvl-a1/packages.nix` did not install the Go toolchain or common editor
  helper binaries, so the extension could not find `go`, `gopls`, or `dlv`.

## Decision

- Install `pkgs.go`, `pkgs.gopls`, and `pkgs.delve` in the `pvl-a1` development
  package group.

## Result

- `pvl-a1` provides the expected Go CLI tools system-wide so VS Code can find
  them through the normal user environment.
