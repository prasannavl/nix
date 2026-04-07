{inputs}: [
  # (import ./unstable-sys.nix {inherit inputs; })
  (import ./unstable.nix {inherit inputs;})
  inputs.vscode-ext.overlays.default
  (import ./pvl.nix {inherit inputs;})
  (import ./pkgs.nix {inherit inputs;})
  (
    final: _: {
      handbrake-wrapped = final.callPackage ../lib/ext/handbrake.nix {};
      vscode-upstream = final.callPackage ../lib/ext/vscode-upstream.nix {};
      zed-wrapped = final.callPackage ../lib/ext/zed.nix {};
      nvidiaCustomForKernel = kernelPackages:
        final.callPackage ../lib/ext/nvidia-driver.nix {inherit kernelPackages;};
      nvidia-custom = final.nvidiaCustomForKernel final.linuxPackages;
    }
  )
]
