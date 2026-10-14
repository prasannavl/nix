# Forward-only member target. Construction does not authorize realization.
{
  pkgs,
  sources,
}: let
  lib = pkgs.lib;
  names = ["baseline" "lockEdit" "manifestEdit" "rustEdit"];
  fail = message: throw "rust-g4-invalidation: ${message}";
  inputGuard =
    if !builtins.isAttrs sources || builtins.attrNames sources != names
    then fail "sources must contain exactly baseline, rustEdit, manifestEdit, lockEdit"
    else if !builtins.all (name: builtins.isPath sources.${name}) names
    then fail "every source must be a materialized evaluator-visible path"
    else true;
  qualifications = builtins.mapAttrs (_: src: import ./default.nix {inherit pkgs src;}) sources;
  evaluation = import ./eval.nix {
    pkgs = pkgs;
    src = sources.baseline;
    variants = builtins.removeAttrs sources ["baseline"];
  };
  # The existing semantic constructor owns the regular fixture-file guard.
  # Interpolation of a path, rather than toString, carries a STORE dependency.
  expectedInputs = builtins.mapAttrs (name: src:
    builtins.seq qualifications.${name}.acceptanceTargets.semantic.buildCommand
    "${src + "/expected-output.txt"}")
  sources;
  expectedContexts = builtins.mapAttrs (_: builtins.getContext) expectedInputs;
  expectedBytes = builtins.mapAttrs (_: src: builtins.readFile (src + "/expected-output.txt")) sources;
  # Comparison-only synthetic controls are not producer certificates.
  stdoutRelationships = values:
    builtins.isAttrs values
    && builtins.attrNames values == names
    && builtins.all (name: builtins.isString values.${name}) names
    && values.baseline != values.rustEdit
    && values.baseline == values.manifestEdit
    && values.baseline == values.lockEdit;
  matrix = {baseline = evaluation.table;} // evaluation.variantTable;
  identity = drv: {
    derivationPath = drv.drvPath;
    output = drv.outputName;
    storePath = drv.outPath;
  };
  contexts =
    builtins.mapAttrs (name: q: let
      consumer = q.consumers.member;
      layer = consumer.passthru.memberLayer;
      base = q.compiledInputs."members/app";
    in {
      materializedSource = toString sources.${name};
      projectDir = "members/app";
      actualConsumerSource = toString consumer.src;
      base = {
        input = base.cargoArtifacts;
        output = base.handle;
        parent = base.actualParent;
        selectedParent = base.selectedParent;
      };
      memberLayer = {
        input = identity layer.cargoArtifacts;
        output = identity layer;
      };
      final = {
        input = identity consumer.cargoArtifacts;
        output = identity consumer;
      };
    })
    qualifications;
  changedConsumer = before: after:
    before.final
    != after.final
    && before.memberLayer != after.memberLayer
    && builtins.all (name: before.checks.${name} != after.checks.${name}) ["fmt" "lint" "test"];
  controls =
    evaluation.assertions
    // {
      expectedInputsAreStoreDependencies = builtins.all (name: let
        context = expectedContexts.${name};
      in
        lib.hasPrefix "/nix/store/" expectedInputs.${name}
        && builtins.attrNames context != []
        && builtins.all (path: context.${path}.path or false) (builtins.attrNames context))
      names;
      expectedOutputRelationships = stdoutRelationships expectedBytes;
      # Member final/layer/check identities invalidate for every edit. Existing
      # eval.nix retains pure compatibility checks, not extra native routes.
      editedMemberConsumerTriples = builtins.all (name:
        changedConsumer matrix.baseline.routes.member matrix.${name}.routes.member)
      ["rustEdit" "manifestEdit" "lockEdit"];
    };
  failed = builtins.filter (name: !controls.${name}) (builtins.attrNames controls);
  constructionGuard =
    if failed != []
    then fail "construction controls failed: ${lib.concatStringsSep ", " failed}"
    else true;
  quote = lib.escapeShellArg;
  observations = lib.concatMapStringsSep "\n" (variant:
    "observe_stdout ${quote variant} "
    + quote (lib.getExe qualifications.${variant}.consumers.member)
    + " ${quote expectedInputs.${variant}} ${quote "${variant}-member.stdout"}")
  names;
  # Metadata must not pull base/peer/check outputs into native realization.
  # Only getExe and expectedInputs above carry native store dependencies.
  identityMatrix = builtins.unsafeDiscardStringContext (builtins.toJSON {
    inherit contexts;
    identities = matrix;
  });
  target =
    pkgs.runCommand "rust-g4-member-invalidation-acceptance" {
      nativeBuildInputs = [pkgs.coreutils pkgs.diffutils];
    } ''
      set -Eeuo pipefail

      observe_stdout() {
        local variant="$1" binary="$2" expected="$3" file="$4"
        timeout 10 "$binary" > "$out/$file"
        cmp "$expected" "$out/$file"
        printf '%s\tmember\t%s\t%s\t%s\tobserved-native-stdout\n' \
          "$variant" "$binary" "$expected" "$file" >> "$out/stdout-files.tsv"
      }

      main() {
        mkdir -p "$out"
        printf 'variant\troute\tbinary\texpected_store_input\tstdout_file\tevidence\n' \
          > "$out/stdout-files.tsv"
        ${observations}
        if cmp -s "$out/baseline-member.stdout" "$out/rustEdit-member.stdout"; then
          echo 'rust edit must change actual stdout' >&2
          return 1
        else
          # cmp status 2 is an error, not successful inequality evidence.
          local comparison_status="$?"
          [[ "$comparison_status" -eq 1 ]]
        fi
        cmp "$out/baseline-member.stdout" "$out/manifestEdit-member.stdout"
        cmp "$out/baseline-member.stdout" "$out/lockEdit-member.stdout"
        printf '%s\n' ${quote identityMatrix} > "$out/constructor-identities.json"
        printf '%s\n' \
          'constructor-identities.json: evaluator observations, not native build evidence.' \
          'Synthetic comparison controls are eval tests, not observed stdout.' \
          'Forward-only four-variant member-mode stdout qualification.' \
          'No activation, default flip, timing, cold-cache or exact-reuse proof.' \
          'No emitted-unit counts, Cargo freshness or resolved unit DAG observation.' \
          'producer.qualified=false; producer.decision=not_proven' > "$out/scope.txt"
      }

      main
    '';
in
  builtins.seq inputGuard (builtins.seq constructionGuard {
    acceptanceTargets = {memberInvalidation = target;};
    inherit contexts controls expectedInputs expectedContexts matrix;
    comparisonControls = {stdoutRelationships = stdoutRelationships;};
    diagnostics = {
      nativeAcceptance = "deferred-explicit-approval-required";
      observation = "constructor identities and fixture expectations; native stdout only upon realization";
      cargoFreshness = "not_observed";
      resolvedUnitInventory = "not_observed";
      producer = {
        qualified = false;
        decision = "not_proven";
      };
    };
  })
