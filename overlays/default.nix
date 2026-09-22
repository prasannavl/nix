{inputs}: [
  # (import ./unstable-sys.nix {inherit inputs; })
  (import ./unstable.nix {inherit inputs;})
  # (import ./sway.nix {inherit inputs;})
  (import ./gdm.nix {inherit inputs;})
  (import ./supergfxctl.nix {inherit inputs;})
  inputs.vscode-ext.overlays.default
  (_final: prev: {
    craneLib = inputs.crane.mkLib prev;
  })
  (import ./pvl.nix {inherit inputs;})
  (import ./pkgs.nix {inherit inputs;})
  (
    final: prev: {
      handbrake-wrapped = final.callPackage ../lib/ext/handbrake.nix {};
      switch-to-configuration-ng = final.callPackage ../lib/ext/switch-to-configuration {
        switch-to-configuration-ng = prev.switch-to-configuration-ng;
      };
      tailscale-upstream = final.callPackage ../lib/ext/tailscale {
        tailscale = final.unstable.tailscale;
      };
      tailscale = final.tailscale-upstream;
      vscode-upstream = final.callPackage ../lib/ext/vscode {};
      zed-wrapped = final.callPackage ../lib/ext/zed.nix {};
      nvidiaCustomForKernel = kernelPackages:
        final.callPackage ../lib/ext/nvidia {inherit kernelPackages;};
      nvidia-custom = final.nvidiaCustomForKernel final.linuxPackages;
      # PrismML llama.cpp fork (ternary GGUF support). Bind-mount either
      # variant over a router container's /app to swap the engine in place.
      prism-llama-cpp-rocm = final.callPackage ../lib/ext/prism-llama-cpp {variant = "rocm";};
      prism-llama-cpp-cuda = final.callPackage ../lib/ext/prism-llama-cpp {variant = "cuda";};
    }
  )
]
