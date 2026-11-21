{
  inputs,
  pkgs,
  system,
}: let
  lib = pkgs.lib;
  upstream = inputs.whisrs.packages.${system}.default;
  unfree = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  # whisper.cpp backend = the cargo feature of the one upstream package plus the
  # half cargo cannot express: the SDK its cmake has to find.
  backends = {
    vulkan = {
      nativeBuildInputs = with pkgs; [shaderc vulkan-headers vulkan-loader];
      buildInputs = with pkgs; [spirv-headers vulkan-headers vulkan-loader];
      env = {
        Vulkan_INCLUDE_DIR = "${pkgs.vulkan-headers}/include";
        Vulkan_LIBRARY = "${pkgs.vulkan-loader}/lib/libvulkan.so";
      };
    };
    cuda = {
      nativeBuildInputs = [unfree.cudaPackages.cuda_nvcc];
      buildInputs = [unfree.cudaPackages.cudatoolkit];
      # No arch list: ggml-cuda already defaults to 86-real/89-real (RTX 3060,
      # RTX 4060) plus PTX virtuals. CMake's knob is the `CUDAARCHS` env var;
      # `CMAKE_CUDA_ARCHITECTURES` is a cache variable that whisper-rs-sys never
      # forwards, so setting it here would be inert.
    };
    hipblas = {
      nativeBuildInputs = with pkgs.rocmPackages; [clr hipblas];
      buildInputs = with pkgs.rocmPackages; [clr hipblas rocblas];
    };
  };

  # Features compose in cargo: `mk ["vulkan" "cuda"]` is one daemon that can use
  # either GPU, `mk []` is the CPU build.
  mk = features: let
    parts = lib.attrVals features backends;
    fromBackends = attr: lib.concatMap (b: b.${attr} or []) parts;
  in
    upstream.overrideAttrs (old: {
      pname = "whisrs${lib.concatMapStrings (f: "-${f}") features}";
      # Through overrideAttrs, only these env attributes reach the cargo hooks:
      # `buildFeatures` is a buildRustPackage *argument*, and setting it here is
      # silently dropped (a `vulkan` build then shipped a CPU-only daemon).
      cargoBuildFeatures = (old.cargoBuildFeatures or []) ++ features;
      cargoCheckFeatures = (old.cargoCheckFeatures or []) ++ features;
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ fromBackends "nativeBuildInputs";
      buildInputs = (old.buildInputs or []) ++ fromBackends "buildInputs";
      env = (old.env or {}) // lib.foldl' (acc: b: acc // (b.env or {})) {} parts;
    });
in {
  inherit mk;
  # Host-facing accelerator names; cargo feature names stay in this file.
  accel = {
    cpu = mk [];
    vulkan = mk ["vulkan"];
    cuda = mk ["cuda"];
    rocm = mk ["hipblas"];
  };
}
