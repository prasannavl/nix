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
  lintApp = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = lintPkgs;
    text = ''
      set -euo pipefail

      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
      cd "''${repo_root}"

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

      collect_changed_files() {
        local -a patterns=("$@")
        local -A seen=()
        local path=""

        emit_unique_from() {
          local -a cmd=("$@")

          while IFS= read -r -d $'\0' path; do
            [ -n "''${path}" ] || continue
            [ -e "''${path}" ] || continue
            if ! [[ -v "seen[''${path}]" ]]; then
              printf '%s\0' "''${path}"
              seen["''${path}"]=1
            fi
          done < <("''${cmd[@]}" 2>/dev/null || true)
        }

        emit_unique_from git diff --name-only -z --cached --diff-filter=ACMR -- "''${patterns[@]}"
        emit_unique_from git diff --name-only -z --diff-filter=ACMR -- "''${patterns[@]}"
        emit_unique_from git ls-files -z --others --exclude-standard -- "''${patterns[@]}"

        if [ "''${#seen[@]}" -eq 0 ] && git rev-parse --verify HEAD^ >/dev/null 2>&1; then
          emit_unique_from git diff --name-only -z --diff-filter=ACMR HEAD^ HEAD -- "''${patterns[@]}"
        fi
      }

      mapfile -d $'\0' -t changed_nix_files < <(collect_changed_files '*.nix')
      mapfile -d $'\0' -t changed_shell_files < <(collect_changed_files '*.sh' '.githooks/*')
      mapfile -d $'\0' -t changed_markdown_files < <(collect_changed_files '*.md')
      mapfile -d $'\0' -t tf_project_dirs < <(find tf -mindepth 1 -maxdepth 1 -type d -name '*-*' -print0 | sort -z)

      printf '[lint] Running shared lint suite\n' >&2
      run_step treefmt 'Checking formatting drift' treefmt --ci "$@"

      if [ "''${#changed_nix_files[@]}" -gt 0 ]; then
        changed_nix_file=

        current_step=statix
        current_step_description='Linting changed Nix files'
        log_step "''${current_step}" "''${current_step_description}"
        for changed_nix_file in "''${changed_nix_files[@]}"; do
          printf '  - %s\n' "''${changed_nix_file}" >&2
          statix check -- "''${changed_nix_file}"
        done

        current_step=deadnix
        current_step_description='Checking changed Nix files for unused bindings'
        log_step "''${current_step}" "''${current_step_description}"
        for changed_nix_file in "''${changed_nix_files[@]}"; do
          printf '  - %s\n' "''${changed_nix_file}" >&2
          deadnix -- "''${changed_nix_file}"
        done
      fi

      if [ "''${#changed_shell_files[@]}" -gt 0 ]; then
        run_step shellcheck 'Linting changed shell files' shellcheck --external-sources --shell=bash "''${changed_shell_files[@]}"
      fi

      run_step actionlint 'Linting GitHub Actions workflows' actionlint

      if [ "''${#changed_markdown_files[@]}" -gt 0 ]; then
        run_step markdownlint 'Linting changed Markdown files' markdownlint-cli2 "''${changed_markdown_files[@]}"
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
  };
  lintDeps = pkgs.buildEnv {
    name = "lint-deps";
    paths = lintPkgs;
  };
in {
  inherit formatterPkgs lintApp lintDeps lintPkgs;

  formatter = pkgs.writeShellApplication {
    name = "treefmt";
    runtimeInputs = formatterPkgs;
    text = "treefmt";
  };

  app = {
    type = "app";
    program = "${lintApp}/bin/lint";
  };
}
