# Execute generated installation/descriptor code only: no Cargo or compilation.
# `script` also permits an isolated evaluator-driven shell check with the pinned
# stdenv's hook dispatcher, without realizing any derivations.
{pkgs}: let
  helper = import ../pkg-helper.nix;
  setupHook = ./fixtures/rust-native-context/post-install-artifacts.sh;
  input = pkgs.makeSetupHook {name = "rust-native-post-install-fixture";} setupHook;
  literal = "$NATIVE_CONTEXT_LITERAL 'quoted' $(not-a-command) `not-a-command` \\ slash\nsecond line";
  factory = helper.mkRustComposition {
    inherit pkgs;
    src = ./fixtures/rust-composition;
    baseMode = "member";
    buildAttrs = {
      nativeBuildInputs = [input];
      env.OPENSSL_DIR = literal;
    };
  };
  args = {
    pname = "application";
    projectDir = "members/application";
  };
  package = factory.mkRustDerivation args;
  redundant = factory.mkRustDerivation (args // {checkEnv.OPENSSL_DIR = literal;});
  scriptFor = drv: drv.passthru.pkgOps.checks.test.envScript;
  quote = pkgs.lib.escapeShellArg;
in
  assert package.postPhases == ["rustFinalOutputCheckPhase"];
  assert scriptFor package == scriptFor redundant;
  assert builtins.elem input package.nativeBuildInputs; {
    script = ''
      runNativeOutputCase() (
        set -euo pipefail
        local caseName="$1" guard="$2" hookStage="$3"
        out="$PWD/output-$caseName-$guard-$hookStage"
        mkdir -p "$out"
        postBuildInstallFromCargoBuildLogOut="$PWD/install-$caseName-$guard-$hookStage"
        mkdir -p "$postBuildInstallFromCargoBuildLogOut"
        printf fixture > "$postBuildInstallFromCargoBuildLogOut/fixture-bin"
        postInstall=${quote (package.postInstall or "")}
        postInstallHooks=()
        postFixupHooks=()
        RUST_TEST_ARTIFACT="$caseName"
        ${builtins.readFile setupHook}
        if [ "$hookStage" = fixup ]; then
          postInstallHooks=()
          postFixupHooks+=(writeRustKnownArtifact)
        fi
        # Execute the actual generated install phase and registered setup hook.
        eval ${quote package.installPhase}
        runHook postFixup
        if [ "$guard" = yes ]; then
          rustFinalOutputCheckPhase=${quote package.rustFinalOutputCheckPhase}
          local phase
          for phase in ${builtins.concatStringsSep " " package.postPhases}; do
            eval "''${!phase}"
          done
        fi
      )
      runNativeOutputCase clean yes install
      for hookStage in install fixup; do
        for artifact in target target.tar.zst target.tar.zst.prev; do
          # Control establishes that installation really produces the path.
          runNativeOutputCase "$artifact" no "$hookStage"
          test -e "$PWD/output-$artifact-no-$hookStage/$artifact" || test -L "$PWD/output-$artifact-no-$hookStage/$artifact"
          set +e
          (set -e; runNativeOutputCase "$artifact" yes "$hookStage") >"$artifact-$hookStage.log" 2>&1
          result=$?
          set -e
          if [ "$result" -eq 0 ]; then
            echo "known Cargo output escaped the final guard: $artifact ($hookStage)" >&2
            exit 1
          fi
          grep -F 'final package must not publish Cargo artifacts:' "$artifact-$hookStage.log"
        done
      done
      checkNativeLiteralEnv() (
        set -euo pipefail
        NATIVE_CONTEXT_LITERAL=must-not-expand
        expected=${quote literal}
        ${scriptFor package}
        test "$OPENSSL_DIR" = "$expected"
        ${scriptFor redundant}
        test "$OPENSSL_DIR" = "$expected"
      )
      checkNativeLiteralEnv
    '';
  }
