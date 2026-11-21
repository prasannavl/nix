moduleArgs @ {
  inputs,
  pkgs,
  ...
}: let
  runtime = (import ../ab).runtime.mk {inherit pkgs;};
  module = runtime.incus.nixos {
    defaultImages = {
      lxc = inputs.self.nixosImages.incus-lxc-base;
      lxcAlias = "nixos-incus-lxc-base";
      vm = inputs.self.nixosImages.incus-vm-base;
      vmAlias = "nixos-incus-vm-base";
    };
  };
in
  module moduleArgs
