{
  inputs ? {},
  providers ? {},
}: [
  (import ./rust/toolchain.nix {
    inherit inputs;
    providers = providers.rust or {};
  }).overlay
  (import ./go/toolchain.nix {inherit inputs;}).overlay
  (import ./nodejs/toolchain.nix {}).overlay
  (import ./deno/toolchain.nix {}).overlay
  (import ./python/toolchain.nix {}).overlay
]
