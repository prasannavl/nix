{pkgs}:
pkgs.runCommand "lint-markdown-test" {
  nativeBuildInputs = [pkgs.bash pkgs.git pkgs.python3 pkgs.treefmt pkgs.deno pkgs.markdownlint-cli2 pkgs.alejandra pkgs.opentofu pkgs.shfmt pkgs.jq];
  LINT_SCRIPT = ../../scripts/lint.sh;
  FMT_SCRIPT = ../../scripts/fmt.sh;
  TREEFMT_CONFIG = ../../treefmt.toml;
  MARKDOWNLINT_CONFIG = ../../.markdownlint-cli2.jsonc;
} ''
  python ${./test_lint_markdown.py} -v
  touch "$out"
''
