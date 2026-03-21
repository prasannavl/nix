# Lint readonly format checks - 2026-03

- Plain `nix run .#lint` must not rewrite files as a side effect of formatting
  validation.
- `treefmt --ci` is not a safe read-only contract for this repo because it still
  executes write-capable formatters and fails after changes are made.
- The non-fix lint path should use formatter-native check modes instead:
  `alejandra --check` for Nix, `deno fmt --check` for JS/Markdown, and
  `tofu fmt -check -write=false -diff -recursive` for Terraform/OpenTofu.
- `nix run .#lint -- fix` can continue using `treefmt` for the actual rewrite
  pass because file mutation is expected in fix mode.
