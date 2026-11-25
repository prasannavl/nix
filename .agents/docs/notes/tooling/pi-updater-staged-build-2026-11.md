# Pi updater staged builds

The npm hash probe and validation build both call the staged `default.nix` with
`pkgs.callPackage` from the repository's locked Nixpkgs. A bare `nix-build` no
longer works for packages with required `pkgs` arguments, including `pi-web`.
The build must import the staged package so it reads the candidate
`sources.nix`, not the checked-in pins.
