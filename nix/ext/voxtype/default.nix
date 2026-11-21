{
  inputs,
  pkgs,
  system,
}: let
  upstream = inputs.voxtype.packages.${system};

  # The GGUF worker stays its own binary: transcribe.cpp and whisper.cpp use
  # incompatible ggml symbols. Upstream's flake builds only the client.
  mkWorker = vulkan:
    pkgs.callPackage ./gguf-worker.nix {
      src = inputs.voxtype.outPath;
      inherit (upstream.voxtype-vulkan-unwrapped) cargoDeps version;
      inherit vulkan;
    };
  workerCpu = mkWorker false;
  workerVulkan = mkWorker true;

  # Upstream ships the ONNX engines, the Whisper backends and the runtime
  # wrappers as separate binaries, each with its own feature list, inputs and
  # runtime environment. Read those, never restate them: the engine sets change
  # with every release.
  onnxBuilds = {
    cpu = {
      src = upstream.voxtype-onnx-unwrapped;
      wrapper = upstream.onnx;
    };
    cuda = {
      src = upstream.voxtype-onnx-cuda-unwrapped;
      wrapper = upstream.onnx-cuda;
    };
    migraphx = {
      src = upstream.voxtype-onnx-migraphx-unwrapped;
      wrapper = upstream.onnx-migraphx;
    };
  };
  whisperBuilds = {
    cpu = upstream.voxtype-unwrapped;
    vulkan = upstream.voxtype-vulkan-unwrapped;
    rocm = upstream.voxtype-rocm-unwrapped;
  };

  # One voxtype = a Whisper backend plus upstream's ONNX engine set in the same
  # binary, so one command serves every engine. Oniguruma is missing from the
  # ONNX build inputs (onig_sys needs it); SQLite is not needed, rusqlite is
  # bundled.
  mk = {
    whisper ? "vulkan",
    onnx ? "cpu",
  }: let
    base = whisperBuilds.${whisper};
    o = onnxBuilds.${onnx};
    label =
      if onnx == "cpu"
      then whisper
      else "${whisper}-${onnx}";
    unwrapped = base.overrideAttrs (old: {
      pname = "voxtype-${label}";
      # Through overrideAttrs only these env attributes reach cargo; the
      # `buildFeatures` argument is already spent by buildRustPackage.
      cargoBuildFeatures = (old.cargoBuildFeatures or []) ++ o.src.cargoBuildFeatures;
      cargoCheckFeatures = (old.cargoCheckFeatures or []) ++ o.src.cargoCheckFeatures;
      buildInputs = (old.buildInputs or []) ++ o.src.buildInputs ++ [pkgs.oniguruma];
      ORT_LIB_LOCATION = o.src.ORT_LIB_LOCATION;
    });
  in
    # The worker only comes in a CPU and a Vulkan build; match Whisper's backend.
    withWorker label (o.wrapper.overrideAttrs (_: {paths = [unwrapped];})) (
      if whisper == "vulkan"
      then workerVulkan
      else workerCpu
    );

  withWorker = label: package: worker:
    pkgs.symlinkJoin {
      name = "voxtype-${label}-with-gguf-worker";
      paths = [package worker];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        test -x "$out/bin/voxtype-gguf-worker"
        wrapProgram "$out/bin/voxtype" \
          --set-default VOXTYPE_GGUF_WORKER "${worker}/bin/voxtype-gguf-worker"
      '';
      inherit (package) meta;
    };
in {
  inherit mk;
  # `cuda` has no upstream Whisper build: Whisper stays on Vulkan and only the
  # ONNX execution provider changes.
  accel = {
    cpu = mk {whisper = "cpu";};
    vulkan = mk {};
    cuda = mk {onnx = "cuda";};
    rocm = mk {
      whisper = "rocm";
      onnx = "migraphx";
    };
  };
}
