# Repository Rust qualification scenarios

This area owns product and repository assumptions used by optional
qualification. The generic Rust library never imports these adapters; the
operator selects a scenario and passes its recipe explicitly to the generic VM
framework.

- `pvl/manager-recipes.nix` retains the original five-member manager/agent
  recipe.
- `pvl/manager-vm.nix` supplies that recipe and the preserved product-source
  inventory to `lib/flake/rust/qualification/recipe-vm.nix`. Its argument
  defaults and `passthru.managerQualification` view are preserved.
- `pvl/manager-patched-vm.nix` is the optional patched-Cargo entrypoint. Patch
  implementation stays in the generic library and is selected explicitly.
- `pvl/product-eval.nix` retains the original Pvl host-agent construction and
  acceptance expectations.
- `abird/recipes.nix` retains the original 24-member/default-off Abird scenario
  and legacy comparison. It requires its matching immutable source inputs.

Both checkouts retain these labeled scenarios for joint qualification replay.
Their presence does not select a repository, register root checks, certify newer
source pins or turn qualification into a production package route.

Generic seed selection accepts explicit `producers`, `excludedOutputs` and
`extraInputs` through `lib/flake/rust/qualification/recipe-seeds.nix`. Each
scenario owns its compiler, vendor and runtime handles. The library does not
know a product name or stack inventory.

All new VM lanes retain 16 CPUs / 16 GiB. Normal systems keep regular Cargo;
patched Cargo and strict independent byte determinism remain optional.
Historical results retain their original source paths and tooling pins.
