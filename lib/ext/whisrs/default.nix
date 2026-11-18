{
  inputs,
  pkgs,
  system,
}: let
  upstream = inputs.whisrs.packages.${system}.default;
  unfree = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  withBackend = backend: nativeDeps: deps:
    upstream.overrideAttrs (old: {
      pname = "whisrs-${backend}";
      buildFeatures = (old.buildFeatures or []) ++ [backend];
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ nativeDeps;
      buildInputs = (old.buildInputs or []) ++ deps;
    });

  vulkan = (withBackend "vulkan" (with pkgs; [
      shaderc
      vulkan-headers
      vulkan-loader
    ]) (with pkgs; [
      spirv-headers
      vulkan-headers
      vulkan-loader
    ])).overrideAttrs (old: {
    env =
      (old.env or {})
      // {
        Vulkan_INCLUDE_DIR = "${pkgs.vulkan-headers}/include";
        Vulkan_LIBRARY = "${pkgs.vulkan-loader}/lib/libvulkan.so";
      };
  });
  cuda = (withBackend "cuda"
    [unfree.cudaPackages.cuda_nvcc]
    [unfree.cudaPackages.cudatoolkit]).overrideAttrs (old: {
    env =
      (old.env or {})
      // {
        # RTX 3060 on L5 and RTX 4060 on A1.
        CMAKE_CUDA_ARCHITECTURES = "86;89";
      };
  });
  rocm =
    withBackend "hipblas"
    (with pkgs.rocmPackages; [clr hipblas])
    (with pkgs.rocmPackages; [clr hipblas rocblas]);
in {
  cpu = upstream;
  inherit vulkan cuda rocm;
}
