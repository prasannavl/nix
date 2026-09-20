{pkgs}: let
  lib = pkgs.lib;
  modelReconciler = import ../. {inherit lib pkgs;};
  probe = pkgs.writeShellScript "model-reconciler-ownership-probe" ''
    source "$MODEL_RECONCILER_OWNERSHIP_LIB"
    model_reconciler_init_state
    model_reconciler_load_state
    test "''${#MODEL_RECONCILER_OWNED_MODELS[@]}" -eq 1
    test "''${MODEL_RECONCILER_OWNED_MODELS[0]}" = "example/model:Q4_K_M"
  '';
  application = modelReconciler.mkApplication {
    helper = probe;
    name = "model-reconciler-wrapper-test";
    runtimeInputs = [pkgs.coreutils pkgs.jq];
  };
  assertionsHold = binding: builtins.all (entry: entry.assertion) binding.assertions;
  validBinding = modelReconciler.mkStateBinding {
    stateDirectory = "ai/reconciler";
    stateName = "ollama.json";
  };
  unsafeDirectoryBinding = modelReconciler.mkStateBinding {
    stateDirectory = "ai/../reconciler";
    stateName = "ollama.json";
  };
  unsafeNameBinding = modelReconciler.mkStateBinding {
    stateDirectory = "ai/reconciler";
    stateName = "../ollama.json";
  };
in
  assert assertionsHold validBinding;
  assert !(assertionsHold unsafeDirectoryBinding);
  assert !(assertionsHold unsafeNameBinding);
    pkgs.runCommand "model-reconciler-wrapper-test" {} ''
      state="$TMPDIR/state/ownership.json"
      legacy="$TMPDIR/legacy.json"
      printf '%s\n' '{"version":1,"models":["example/model:Q4_K_M"]}' > "$legacy"
      STATE_DIRECTORY="$(dirname "$state")" \
        MODEL_RECONCILER_STATE_NAME="$(basename "$state")" \
        MODEL_RECONCILER_LEGACY_STATE_FILE="$legacy" \
        ${lib.getExe application}
      ${lib.getExe pkgs.jq} -e \
        '.version == 1 and .models == ["example/model:Q4_K_M"]' \
        "$state" >/dev/null
      touch "$out"
    ''
