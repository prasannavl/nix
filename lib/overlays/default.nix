{inputs}: let
  ab = import ../../ab;
in
  (ab.core.toolchainOverlays {inherit inputs;})
  ++ [
    # (import ./unstable-sys.nix {inherit inputs; })
    (import ./unstable.nix {inherit inputs;})
    # (import ./sway.nix {inherit inputs;})
    (import ./gdm.nix {inherit inputs;})
    (import ./niri.nix)
    (import ./tmux-plugins.nix)
    (import ./supergfxctl.nix {inherit inputs;})
    inputs.vscode-ext.overlays.default
    (import ./rust-policy.nix)
    (import ./pgadmin4)
    (import ./pvl.nix {inherit inputs;})
    (import ./pkgs.nix {inherit inputs;})
    (import ./agent-tools.nix)
    (import ./voice.nix {inherit inputs;})
    (
      final: prev: {
        handbrake-wrapped = final.callPackage ../ext/handbrake.nix {};
        switch-to-configuration-ng = final.callPackage ../ext/switch-to-configuration {
          switch-to-configuration-ng = prev.switch-to-configuration-ng;
        };
        tailscale-upstream = final.callPackage ../ext/tailscale {
          ab = ab.core.mk {pkgs = final;};
          tailscale = final.unstable.tailscale;
        };
        tailscale = final.tailscale-upstream;
        # 1.1.19 in the pinned nixpkgs fails two dbus tests under xvfb (no
        # machine-id in the sandbox); 1.1.20 from unstable builds.
        solaar = final.unstable.solaar;
        stalwart-cli = final.callPackage ../ext/stalwart-cli {};
        vscode-upstream = final.callPackage ../ext/vscode {};
        zed-wrapped = final.callPackage ../ext/zed.nix {};
        # Upstream-following external units that are not agent tooling; the
        # agent-facing ones live in lib/overlays/agent-tools.nix.
        tuicr = final.callPackage ../ext/tuicr {};
        kache = final.callPackage ../ext/kache {};
        # Prebuilt release binaries; neither tool is in nixpkgs.
        oyo = final.callPackage ../ext/oyo {};
        diffx = final.callPackage ../ext/diffx {};
        nvidiaCustomForKernel = kernelPackages:
          final.callPackage ../ext/nvidia {inherit kernelPackages;};
        nvidia-custom = final.nvidiaCustomForKernel final.linuxPackages;
        # PrismML llama.cpp fork (ternary GGUF support). Bind-mount either
        # variant over a router container's /app to swap the engine in place.
        prism-llama-cpp-rocm = final.callPackage ../ext/prism-llama-cpp {variant = "rocm";};
        prism-llama-cpp-cuda = final.callPackage ../ext/prism-llama-cpp {variant = "cuda";};
      }
    )
  ]
