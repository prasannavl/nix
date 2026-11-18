{
  inputs,
  pkgs,
  system,
}: let
  upstream = inputs.voxtype.packages.${system};

  mkWorker = vulkan:
    pkgs.callPackage ./gguf-worker.nix {
      src = inputs.voxtype.outPath;
      inherit (upstream.voxtype-vulkan-unwrapped) cargoDeps version;
      inherit vulkan;
    };
  workerCpu = mkWorker false;
  workerVulkan = mkWorker true;

  # Upstream links to system SQLite; ONNX additionally needs Oniguruma.
  # Keep the original upstream wrapper byte-for-byte, changing only its
  # unwrapped build dependencies.
  withLibraries = extra: package:
    package.overrideAttrs (old: {
      buildInputs = (old.buildInputs or []) ++ [pkgs.sqlite] ++ extra;
    });
  patched = extra: wrapper: unwrapped:
    wrapper.overrideAttrs (_: {
      paths = [(withLibraries extra unwrapped)];
    });
  whisper = patched [];
  onnx = patched [pkgs.oniguruma];

  withWorker = package: worker:
    pkgs.symlinkJoin {
      name = "${package.name}-with-gguf-worker";
      paths = [package worker];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        test -x "$out/bin/voxtype-gguf-worker"
        wrapProgram "$out/bin/voxtype" \
          --set-default VOXTYPE_GGUF_WORKER "${worker}/bin/voxtype-gguf-worker"
      '';
      inherit (package) meta;
    };

  # Alternate engines expose separate commands rather than conflicting
  # with the standard Whisper daemon binary.
  asCommand = name: package: worker:
    pkgs.writeShellScriptBin name ''
      export VOXTYPE_GGUF_WORKER="''${VOXTYPE_GGUF_WORKER:-${worker}/bin/voxtype-gguf-worker}"
      exec ${package}/bin/voxtype "$@"
    '';
in {
  cpu = withWorker (whisper upstream.default upstream.voxtype-unwrapped) workerCpu;
  vulkan = withWorker (whisper upstream.vulkan upstream.voxtype-vulkan-unwrapped) workerVulkan;
  rocm = withWorker (whisper upstream.rocm upstream.voxtype-rocm-unwrapped) workerCpu;
  onnxCpu = asCommand "voxtype-onnx" (onnx upstream.onnx upstream.voxtype-onnx-unwrapped) workerVulkan;
  onnxCuda = asCommand "voxtype-onnx-cuda" (onnx upstream.onnx-cuda upstream.voxtype-onnx-cuda-unwrapped) workerVulkan;
  onnxMigraphx = asCommand "voxtype-onnx-migraphx" (onnx upstream.onnx-migraphx upstream.voxtype-onnx-migraphx-unwrapped) workerVulkan;
  ggufWorkerCpu = workerCpu;
  ggufWorkerVulkan = workerVulkan;
}
