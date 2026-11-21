{
  lib,
  rustPlatform,
  cmake,
  pkg-config,
  clang,
  llvmPackages,
  shaderc,
  spirv-headers,
  vulkan-headers,
  vulkan-loader,
  src,
  cargoDeps,
  version,
  vulkan ? true,
}:
rustPlatform.buildRustPackage {
  pname = "voxtype-gguf-worker" + lib.optionalString vulkan "-vulkan";
  inherit version src cargoDeps;

  # transcribe.cpp and whisper.cpp use incompatible ggml symbols; the
  # companion must remain its own Cargo package, not a Voxtype bin target.
  cargoBuildFlags = ["-p" "voxtype-gguf-worker"];
  # An argument, not an overrideAttrs attribute: buildRustPackage turns it into
  # the cargoBuildFeatures env var the cargo hooks read.
  buildFeatures = lib.optional vulkan "vulkan";
  doCheck = false;

  nativeBuildInputs =
    [cmake pkg-config clang llvmPackages.libclang]
    ++ lib.optionals vulkan [shaderc];
  buildInputs =
    lib.optionals vulkan [spirv-headers vulkan-headers vulkan-loader];

  LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";
  env =
    {
      CARGO_PROFILE_RELEASE_LTO = "false";
      CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "8";
    }
    // lib.optionalAttrs vulkan {
      Vulkan_INCLUDE_DIR = "${vulkan-headers}/include";
      Vulkan_LIBRARY = "${vulkan-loader}/lib/libvulkan.so";
    };

  postInstall = ''
    test -x "$out/bin/voxtype-gguf-worker"
  '';

  meta = {
    description = "Separate GGUF transcription worker for Voxtype";
    license = lib.licenses.mit;
    mainProgram = "voxtype-gguf-worker";
    platforms = lib.platforms.linux;
  };
}
