{inputs}: [
  # (import ./unstable-sys.nix {inherit inputs; })
  (import ./unstable.nix {inherit inputs;})
  inputs.vscode-ext.overlays.default
  (import ./pvl.nix {inherit inputs;})
  (
    final: prev: {
      handbrake-wrapped = final.callPackage ../pkgs/handbrake.nix {};
      nvidiaCustomForKernel = kernelPackages:
        final.callPackage ../pkgs/nvidia-driver.nix {inherit kernelPackages;};
      nvidia-custom = final.nvidiaCustomForKernel final.linuxPackages;
    }
  )
]
