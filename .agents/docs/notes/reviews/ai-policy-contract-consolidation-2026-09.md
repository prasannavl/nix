# AI Policy Contract Consolidation, 2026-09

## Scope

This follow-up validates the independent reviews of the last 15 Pvl commits and
the Abird parity port, then repairs the shared AI policy surface in both
repositories. Shared production code, tests, and the ownership design document
remain byte- and mode-identical. Abird keeps only its repository-specific
consumer projection and documentation adaptations.

## Design decisions

- `analyzeCatalog` is the sole fleet-wide catalog admission authority. It
  validates entries, backend references, runtime names, llama-router preset
  syntax, and duplicate client/backend identities before any attrset projection
  can silently overwrite data.
- `resolvePolicy` consumes catalog analysis and exclusively owns auto-selection,
  explicit-selection diagnostics, role resolution, backend membership, and
  per-runtime partitions. The module maps its diagnostics to assertions rather
  than reimplementing policy.
- Whole-catalog validation is deliberately fail-closed. The catalog is one
  deployable policy artifact; an invalid dormant entry blocks the new generation
  instead of becoming a latent failure on the first host that later selects it.
- `mkProjection.moduleConfig` is the only cross-repository module handoff. It
  contains the selected catalog, resolved model keys, roles, and sanitized
  declaration-owned backend fields. Evaluated fields such as ports, URLs,
  service names, active flags, and runtime projections cannot feed back into
  read-only module options.
- Preset validation and rendering share one pure llama-router library. Model
  references, aliases, option names, and option values reject empty or multiline
  values before generating `models.ini`.
- The old `services/ai/default.nix` policy helpers and `servableModels` surface
  are removed. Tests and callers use `resolvePolicy`, preventing future drift
  between admission predicates.
- Runtime output is a typed submodule. Missing runtime declarations now produce
  `unknown-llama-runtime` even on hosts declaring no runtimes; a working Ollama
  membership still intentionally makes an unused llama runtime irrelevant.
- PrismML release archives are container filesystem payloads, not native Nix
  executables. Their binaries retain a conventional `/lib64` interpreter, so the
  package no longer advertises a host wrapper or `meta.mainProgram`.

## Abird consumer boundary

Abird validates the pure projection before dereferencing role defaults, giving
one aggregated policy error instead of a raw missing-attribute failure. Its
`services.ai` bridge consumes `moduleConfig`; consumers continue reading the
validated `defaults` and API projections.

## Validation

- Focused AI library, projection, module, llama-router, and PrismML package
  checks passed in both worktrees.
- A custom catalog round-tripped through `moduleConfig` and the evaluated
  module, proving that catalog identity is preserved and derived fields are
  excluded.
- No-build flake checks passed for every host and check derivation in both
  repositories, and both repository lint suites passed.
- The `pvl-a1`, `pvl-l5`, `pvl-x2`, and `abird-srv` system closures built.
- Recursive content comparison passed for the complete shared AI, llama-router,
  and PrismML trees. Shared file-mode comparison and the shared
  test/design-document comparisons also passed.
