{pkgs}:
pkgs.runCommand "lint-events-test" {
  nativeBuildInputs = [pkgs.bash pkgs.git pkgs.python3 pkgs.treefmt pkgs.deno pkgs.markdownlint-cli2];
  LINT_SCRIPT = ../../scripts/lint.sh;
  TREEFMT_CONFIG = ../../treefmt.toml;
  MARKDOWNLINT_CONFIG = ../../.markdownlint-cli2.jsonc;
} ''
  python ${./test_lint_events.py}
  touch "$out"
''
