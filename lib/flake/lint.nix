{pkgs}: let
  formatterPkgs = with pkgs; [
    treefmt
    alejandra
    deno
    opentofu
  ];
  lintPkgs =
    formatterPkgs
    ++ (with pkgs; [
      git
      statix
      deadnix
      shellcheck
      actionlint
      markdownlint-cli2
      tflint
    ]);
  lintScript = mode: ''
    set -euo pipefail

    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
    cd "''${repo_root}"

    lint_scope='${mode}'
    current_step=""
    current_step_description=""

    report_exit() {
      local exit_code="$1"

      if [ "''${exit_code}" -ne 0 ]; then
        if [ -n "''${current_step}" ]; then
          printf '\n[lint] FAILED at %s: %s\n' "''${current_step}" "''${current_step_description}" >&2
        else
          printf '\n[lint] FAILED before a lint step completed\n' >&2
        fi
      fi
    }

    trap 'report_exit "$?"' EXIT

    log_step() {
      printf '\n[%s] %s\n' "$1" "$2" >&2
    }

    run_step() {
      current_step="$1"
      current_step_description="$2"
      shift 2

      log_step "''${current_step}" "''${current_step_description}"
      "$@"
    }

    emit_unique_existing_from() {
      local -n seen_ref="$1"
      shift
      local -a cmd=("$@")
      local path=""

      while IFS= read -r -d $'\0' path; do
        [ -n "''${path}" ] || continue
        [ -e "''${path}" ] || continue
        if ! [[ -v "seen_ref[''${path}]" ]]; then
          printf '%s\0' "''${path}"
          seen_ref["''${path}"]=1
        fi
      done < <("''${cmd[@]}" 2>/dev/null || true)
    }

    collect_diff_files() {
      local -a patterns=("$@")
      local -A seen=()

      emit_unique_existing_from seen git diff --name-only -z --cached --diff-filter=ACMR -- "''${patterns[@]}"
      emit_unique_existing_from seen git diff --name-only -z --diff-filter=ACMR -- "''${patterns[@]}"
      emit_unique_existing_from seen git ls-files -z --others --exclude-standard -- "''${patterns[@]}"

      if [ "''${#seen[@]}" -eq 0 ] && git rev-parse --verify HEAD^ >/dev/null 2>&1; then
        emit_unique_existing_from seen git diff --name-only -z --diff-filter=ACMR HEAD^ HEAD -- "''${patterns[@]}"
      fi
    }

    collect_repo_files() {
      local -a patterns=("$@")
      local -A seen=()

      emit_unique_existing_from seen git ls-files -z --cached --others --exclude-standard -- "''${patterns[@]}"
    }

    collect_files() {
      if [ "''${lint_scope}" = diff ]; then
        collect_diff_files "$@"
      else
        collect_repo_files "$@"
      fi
    }

    mapfile -d $'\0' -t nix_files < <(collect_files '*.nix')
    mapfile -d $'\0' -t shell_files < <(collect_files '*.sh' '.githooks/*')
    mapfile -d $'\0' -t markdown_files < <(collect_files '*.md')
    mapfile -d $'\0' -t tf_project_dirs < <(find tf -mindepth 1 -maxdepth 1 -type d -name '*-*' -print0 | sort -z)

    printf '[lint] Running shared lint suite (%s)\n' "''${lint_scope}" >&2
    run_step treefmt 'Checking formatting drift' treefmt --ci "$@"

    if [ "''${#nix_files[@]}" -gt 0 ]; then
      nix_file=

      current_step=statix
      current_step_description="Linting ''${lint_scope} Nix files"
      log_step "''${current_step}" "''${current_step_description}"
      for nix_file in "''${nix_files[@]}"; do
        printf '  - %s\n' "''${nix_file}" >&2
        statix check -- "''${nix_file}"
      done

      current_step=deadnix
      current_step_description="Checking ''${lint_scope} Nix files for unused bindings"
      log_step "''${current_step}" "''${current_step_description}"
      for nix_file in "''${nix_files[@]}"; do
        printf '  - %s\n' "''${nix_file}" >&2
        deadnix -- "''${nix_file}"
      done
    fi

    if [ "''${#shell_files[@]}" -gt 0 ]; then
      run_step shellcheck "Linting ''${lint_scope} shell files" shellcheck --external-sources --shell=bash "''${shell_files[@]}"
    fi

    run_step actionlint 'Linting GitHub Actions workflows' actionlint

    if [ "''${#markdown_files[@]}" -gt 0 ]; then
      run_step markdownlint "Linting ''${lint_scope} Markdown files" markdownlint-cli2 "''${markdown_files[@]}"
    fi

    if [ "''${#tf_project_dirs[@]}" -gt 0 ]; then
      local_tf_dir=
      current_step=tflint
      current_step_description='Linting Terraform/OpenTofu projects'
      log_step "''${current_step}" "''${current_step_description}"
      for local_tf_dir in "''${tf_project_dirs[@]}"; do
        printf '  - %s\n' "''${local_tf_dir}" >&2
        tflint --chdir "''${local_tf_dir}"
      done
    fi
  '';
  lintApp = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = lintPkgs;
    text = lintScript "full";
  };
  lintDiffApp = pkgs.writeShellApplication {
    name = "lint-diff";
    runtimeInputs = lintPkgs;
    text = lintScript "diff";
  };
  lintDeps = pkgs.buildEnv {
    name = "lint-deps";
    paths = [
      lintApp
      lintDiffApp
    ];
  };
in {
  inherit formatterPkgs lintApp lintDeps lintDiffApp lintPkgs;

  formatter = pkgs.writeShellApplication {
    name = "treefmt";
    runtimeInputs = formatterPkgs;
    text = "treefmt";
  };

  app = {
    type = "app";
    program = "${lintApp}/bin/lint";
  };

  diffApp = {
    type = "app";
    program = "${lintDiffApp}/bin/lint-diff";
  };

  apps = {
    lint = {
      type = "app";
      program = "${lintApp}/bin/lint";
    };
    "lint-diff" = {
      type = "app";
      program = "${lintDiffApp}/bin/lint-diff";
    };
  };

  packages = {
    lint = lintApp;
    "lint-deps" = lintDeps;
    "lint-diff" = lintDiffApp;
  };
}
