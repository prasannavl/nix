# Llama Runtimes, Membership-by-Ref, and the PrismML Fork, 2026-09

## Decision

Two related changes landed together so the ternary Bonsai 2 27B preview can run
on `pvl-a1` without disturbing the existing models:

1. **Model membership is derived from the catalog schema.** `services.ai.models`
   is the only selection list. A selected catalog entry joins a backend exactly
   when it carries that backend's reference field (`ollama`, `llama`), so
   `services.ai.backends.ollama.models` and
   `services.ai.backends.llamaRouter.models` are gone. An entry with no backend
   reference is a configuration error (`unserved` assertion) instead of a
   silently unserved model, and Ollama is never asked to hold a model that has
   no `ollama` ref.
2. **llama.cpp engines are named and isolated.** `llama.runtime` on the catalog
   `llama` ref selects the engine (`default`, the upstream build, by default;
   `prism` for the fork). Each declared runtime under
   `backends.llamaRouter.runtimes.<name>` owns its own deployments, cache
   directory, reconciler state file, reconciler units, `preservedModels`, and
   `idleTimeoutSeconds`. An `llama.runtime` naming an undeclared engine fails
   evaluation.

## Membership-by-ref API

Catalog entry shape (unchanged fields, new semantics):

```nix
bonsai-2-27b = {
  id = "bonsai2:27b";
  hf = "prism-ml/Ternary-Bonsai-2-27B"; # informational (vLLM/SGLang)
  llama = {
    ref = "prism-ml/Ternary-Bonsai-2-27B-gguf:PTQ1_0";
    runtime = "prism";
    preset.jinja = "true";
  };
};
```

- `hasBackend backend entry` is `missingRefs backend [entry] == []`, so
  membership is decided by the presence of a valid `ref`.
- `unknownLlamaRuntime` only fires when the host declares at least one runtime,
  so an Ollama-only host (`pvl-x2`) that never deploys a router is not flagged
  for merely carrying `llama` refs in the shared catalog.
- `runtimesInfo.<runtime>` is a read-only projection (`urls`, `ports`,
  `portsByName`, `serviceNames`, `readyTarget`, `requiredModels`,
  `modelPresets`, `cacheDir`, `active`). Hosts read resolved cache paths from it
  instead of recomputing them.

Per-runtime naming (the `default` runtime keeps the historical names for
compatibility):

| runtime  | reconciler unit                      | worker unit              | state file                 | default cache                             |
| -------- | ------------------------------------ | ------------------------ | -------------------------- | ----------------------------------------- |
| default  | `<stack>-llama-router-models`        | `...-models-load`        | `llama-router.json`        | `/var/lib/<stack>/ai/llama-router`        |
| `<name>` | `<stack>-llama-router-<name>-models` | `...-<name>-models-load` | `llama-router-<name>.json` | `/var/lib/<stack>/ai/llama-router-<name>` |

`idleTimeoutSeconds` is now per runtime and renders as the models.ini `[*]`
section for that engine only.

### Module-evaluation gotcha

The module's reconciler bindings cannot be assembled with a `mkMerge` list
derived from `config` at the top level: resolving the merge's definition paths
would force `config.services.ai.backends.llamaRouter.runtimes` before the
configuration fixpoint exists (`infinite recursion encountered`). The fix keeps
the content keys static and forces the runtime list only inside option values:

```nix
(mkIf
  (stackReady && selectionValid)
  {
    systemd.user.services = lib.mkMerge (builtins.map (b: b.systemd.user.services) activeRuntimeBindings);
    systemd.user.targets = lib.mkMerge (builtins.map (b: b.systemd.user.targets) activeRuntimeBindings);
    assertions = builtins.concatLists (builtins.map (b: b.assertions) activeRuntimeBindings);
  })
```

`activeRuntimeBindings` filters on a deployment-only predicate, not on the
compose projection: the models.ini assignment feeds the same compose instances
that the projection reads, so reading the projection while choosing runtimes
would close a second cycle.

## PrismML llama.cpp fork

- Unit: `lib/ext/prism-llama-cpp/{default.nix,sources.nix,update.sh}`.
  `sources.nix` is `kind = "github-release"` (`PrismML-Eng/llama.cpp`), and the
  unit ships an executable `update.sh` because the generic reporter does not
  support that kind. `default.nix` takes `variant = "rocm" | "cuda"`, fetches
  `llama-<version>-<target>.tar.gz`, and copies the flat `llama-<version>/`
  contents to `$out` with no `patchelf` (RUNPATH is `$ORIGIN`).
- Overlay: `prism-llama-cpp-rocm` and `prism-llama-cpp-cuda`.
- Release: `prism-b10709-9a9394a`; hashes
  `rocm = sha256-Iw+HnVOLufeU0lyQi8jA9nZ3TEHD5w6nGRMchtiZhB0=`,
  `cuda = sha256-iuxn6wI7JRcSx+ZJDzZ7VnG/WH7O0UNqm4X0qQw7fT0=`.
- Runtime swap: the fork store directory is mounted over `/app:ro` in the router
  container. The stock `server-{rocm,cuda}-v0.4.1` images put the entrypoint and
  shared libraries in `/app` and the accelerator userspace in
  `/opt/rocm-7.2.1/lib` / CUDA 12.8, which match the fork's RUNPATH, so the swap
  needs no image build and no OCI registry.
- Quant: `PTQ1_0` (5.9 GB) rather than `PQ2_0` (7.2 GB). Vision uses the fork's
  default `--mmproj-auto`; no extra preset key.

## Host wiring

`pvl-a1` (`hosts/pvl-a1/services/{ai,llama-router}.nix`):

- `runtimes.default`: `llama-router` auto (ROCm, `11000`) +
  `llama-router-nvidia` manual (CUDA, `12000`), `idleTimeoutSeconds = 300`.
- `runtimes.prism`: `llama-router-prism` auto (ROCm, `11001`) +
  `llama-router-prism-nvidia` manual (CUDA, `12001`),
  `idleTimeoutSeconds = 300`; both mount the fork over `/app` and use a separate
  cache, so the default engine never scans ternary GGUFs. Prism ports sit one
  above their default-engine counterpart (`+1`) instead of opening a new range.
- `models` adds `bonsai-2-27b`.

`pvl-l5` uses `runtimes.default` only (no prism runtime, no Bonsai); `pvl-x2` is
Ollama-only and needed no change.

## Validation

- `lib-ai-lib`, `lib-ai-module`, `lib-llama-router-{helper,module}`,
  `lib-ollama-{helper,module}`, and `lib-model-reconciler-wrapper` pass.
- `nixosConfigurations.{pvl-a1,pvl-l5,pvl-x2}.config.system.build.toplevel`
  evaluate (the new unit was untracked during development, so validation used a
  `path:` ref; the committed tree evaluates with the normal `.` ref).
- `prism-llama-cpp-rocm` and `prism-llama-cpp-cuda` build from their fixed
  hashes.

## Deferred: collapsing to a single fork runtime

The fork is upstream llama.cpp plus ternary support, so it can in principle
serve every GGUF the catalog selects; two runtimes are not strictly required. We
keep both for now and revisit a single-runtime setup later.

Evidence gathered (`strings libllama.so` arch/impl tokens):

- Fork release `prism-b10709-9a9394a` is upstream **b10709** plus PrismML
  patches. The stock image
  `ghcr.io/ggml-org/llama.cpp:server-{rocm,cuda}-v0.4.1` is upstream **b10964**
  (revision `b29c606`, image created 2026-09-14), so the fork base is roughly
  255 builds older.
- The fork's `libllama.so` recognises every family the catalog serves: `gemma4`,
  `gemma4-assistant`, `gemma3n`, `qwen3`, `qwen35`, `qwen3moe`, `qwen35moe`,
  `qwen3next`, `nomic-bert`, and `gpt-oss`.
- The only arch string the stock image has that the fork lacks is `qwen4exp`,
  which no catalog entry uses.

Why both runtimes stay: the fork is a preview on an older baseline, so standard
models keep running on current upstream and only Bonsai depends on the fork.
Collapsing would put every model on b10709 and give up new arch/fix coverage
until the fork rebases.

How to do (c) later if desired:

1. Live-load one of the newer catalog models (for example a `gemma4` or `qwen35`
   ref) with the fork `llama-server` to confirm end-to-end, not just arch-string
   presence. Re-run the `libllama.so` token diff against the then current
   catalog and stock image.
2. Point the `default` runtime at the fork overlay and delete the `prism`
   runtime, the stock image pair, and `runtime = "prism"` on `bonsai-2-27b`.
   Bonsai then binds to `default` like every other llama model.
3. Keep the generic `runtimes` option: it still isolates state/cache if another
   engine is added later.

## Client profiles (Codex, Pi, OpenCode)

Client configuration is mutable user state outside this repo. Bonsai was added
to the `pvl-a1` clients only: `pvl-l5` has no prism runtime, and the optional
remote-provider phase (reaching `pvl-a1` ports from another host) was skipped
because the prism ports are not reachable cross-host. The existing named-port
convention (`pvl-ai-backend-port-convention-2026-09.md`) is extended with a
runtime suffix rather than a new port range:

| client   | file                                | new providers (alias `bonsai2:27b`)                         |
| -------- | ----------------------------------- | ----------------------------------------------------------- |
| Pi       | `~/.pi/agent/models.json`           | `local-llama-prism` (11001), `local-nv-llama-prism` (12001) |
| OpenCode | `~/.config/opencode/opencode.jsonc` | `local-llama-prism` (11001), `local-nv-llama-prism` (12001) |
| Codex    | `~/.codex/*.config.toml`            | none (see below)                                            |

- The Pi providers are cloned from `local-llama` (`api = "openai-completions"`,
  `supportsDeveloperRole = false`, `supportsReasoningEffort = false`) and the
  model entry uses `reasoning: true` with
  `compat.thinkingFormat = "qwen-chat-template"`, matching the `qwen3.5`
  entries. Bonsai's template accepts `chat_template_kwargs.enable_thinking`, so
  Pi's `--thinking` works: `off` yields a short answer, `on` streams
  `reasoning_content`.
- The OpenCode blocks mirror `local-llama`/`local-nv-llama`
  (`@ai-sdk/openai-compatible`) with a single `bonsai2:27b` model. OpenCode has
  no thinking control, so Bonsai reasons by default.
- Codex is intentionally unchanged. The fork does serve `/v1/responses`, but the
  Bonsai Jinja template rejects Codex's sequence of developer messages with
  `Jinja Exception: System message must be at the beginning`, exactly like the
  Qwen 3.5 entries. Codex therefore still exposes only `gemma4:e2b`/`e4b`.

Backups were written next to the edited files on `pvl-a1`
(`models.json.bak-bonsai-<ts>`, `opencode.jsonc.bak-bonsai-<ts>`).

### Client validation

- Catalog metadata (`GET :11001/v1/models`): `n_ctx = 109568` (train 262144),
  `n_params = 26895998464`, text+image input, `PTQ1_0 - 1.75 bpw ternary`.
- Raw probes on `pvl-a1`: system+user completion, tool call
  (`get_weather {city: Paris}`), and `enable_thinking` on/off all behave.
- Pi end-to-end: a headless run with `--thinking off` against
  `local-llama-prism/bonsai2:27b` returned `READY-PI` (`stop`, 4 output tokens,
  0 reasoning tokens).
- OpenCode end-to-end: the model list includes both prism providers, and a run
  reaches the model and generates. However, a first turn prefills the ~9k-token
  agent prompt at ~10 tok/s before Bonsai reasons, so a full turn takes minutes
  on the `pvl-a1` iGPU.

### Caveat: poisoned slot after cancellation

Cancelling a prism generation mid-stream (for example a client timeout) can
leave the fork `llama-server` emitting an endless `/` repetition loop, even on
inputs that previously worked.
`systemctl --user restart
pvl-llama-router-prism.service` clears it. Re-test
after a fork update.

## Residual risks

- The fork is a preview build; its `--models-preset`/`--models-max` surface is
  assumed compatible with v0.4.1. Re-verify `lib-llama-router-module` and a live
  `llama-server --help` after each fork update.
- The `/app` mount-over assumes the stock image keeps its ROCm/CUDA userspace
  outside `/app`. A future stock image revision could invalidate that; pin the
  image tag with the fork release.
