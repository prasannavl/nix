{inputs}: [
  # (import ./unstable-sys.nix {inherit inputs; })
  (import ./unstable.nix {inherit inputs;})
  inputs.vscode-ext.overlays.default
  (import ./pvl.nix {inherit inputs;})
  (import ./pkgs.nix {inherit inputs;})
  (
    final: _: {
      handbrake-wrapped = final.callPackage ../pkgs/ext/handbrake.nix {};
      vscode-upstream = final.callPackage ../pkgs/ext/vscode-upstream.nix {};
      zed-wrapped = final.callPackage ../pkgs/ext/zed.nix {};
      nvidiaCustomForKernel = kernelPackages:
        final.callPackage ../pkgs/ext/nvidia-driver.nix {inherit kernelPackages;};
      nvidia-custom = final.nvidiaCustomForKernel final.linuxPackages;
    }
  )
]
