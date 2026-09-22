# AI Selection And Runtime Hardening Review, 2026-09

## Scope

Repair of the shared AI selection/runtime implementation following the Abird
last-15-commit review, followed by a comparison with the independent
`ai-policy-resolution-20260922` Pvl worktree. The final design combines its
single-resolver and null-port improvements with this worktree's configured-
membership semantics and fail-closed runtime integrations.

## Decisions

- Catalog references express capability. Configured membership requires a valid
  reference and a backend deployment; llama.cpp additionally requires a matching
  runtime deployment.
- Nullable and explicit selections use the same membership predicate. Every
  selected model must have at least one configured backend.
- One pure `resolvePolicy` authority validates catalog and selection identity,
  roles, backend refs, runtime types, and llama presets, then emits structured
  diagnostics and backend/runtime partitions. An unused llama capability does
  not invalidate a model served by Ollama.
- Duplicate client IDs, selection keys, Ollama refs, and per-runtime llama refs
  fail before attrset projections can silently overwrite entries.
- Runtimes with deployments must have distinct resolved cache directories.
- The module consumes the resolver internally and exposes the data-only,
  strongly typed `services.ai.resolvedModels` result instead of a broad
  `services.ai.projection` attrset. Abird's repository-level declaration-only
  `moduleConfig` and API helpers remain derived outputs of the same resolver.
- Unresolved deployment ports are `null` and omitted from endpoint/collision
  projections, so missing instances produce their causal errors rather than a
  fake duplicate-port error on a sentinel value.
- llama-router preset rendering is pure and separate from user-bound reconciler
  construction.
- Existing NATS streams fail closed on subject, storage, retention, or consumer
  drift. Only a successful JSON stream listing that establishes absence
  authorizes creation; other lookup failures stop without mutation. PrismML
  packages expose only their intact `/app` container payload, not a misleading
  host executable; their updater uses the process-local GitHub token bridge.

## Validation

- Focused AI library, projection, module, llama-router, NATS convergence, and
  PrismML package/updater checks passed in both isolated worktrees.
- Direct pure-evaluation probes confirmed that Ollama plus Prism admits all 16
  servable catalog models without treating unused default-runtime references as
  errors, while an empty runtime declaration admits none.
- A temporary local NATS 2.14.4 server with CLI 0.4.0 confirmed the JSON stream
  listing contract used to distinguish absence from lookup failure; its state
  was moved to trash after the probe.
- All seven Pvl system closures built with import-from-derivation disabled.
- `nix flake check --no-build --option allow-import-from-derivation false .`
  passed across every Pvl host and check derivation.
- `nix run .#lint` passed.
- The independent policy worktree's focused checks also passed, but direct
  probes found its legacy helper admitted empty runtime declarations and its
  resolver rejected Ollama-served models for unused undeclared llama runtimes.
  Those semantics were deliberately not ported.
