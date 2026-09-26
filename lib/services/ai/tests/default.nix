{pkgs}: {
  model-prefetch =
    pkgs.runCommand "ai-model-prefetch-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.getent
        pkgs.jq
        pkgs.python3
        pkgs.util-linux
      ];
    } ''
      export AI_MODEL_PREFETCH_LIB=${../model-prefetch.sh}
      export AI_MODEL_PREFETCH_CACHE_PREPARER=${../model-prefetch-cache.py}
      export AI_STORAGE_PATH_CONTRACT=${./fixtures/storage-path-contract.json}
      python ${./test_model_prefetch.py}
      touch "$out"
    '';
  lib = import ./lib.nix {inherit pkgs;};
  module = import ./module.nix {inherit pkgs;};
  projection = import ./projection.nix {inherit pkgs;};
}
