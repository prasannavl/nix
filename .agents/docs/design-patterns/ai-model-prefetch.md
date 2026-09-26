# AI Model Catalog And Pre-Activation Prefetch

## One catalog, separate runtime ownership

`lib/services/ai/catalog.nix` is the only shared model catalog. Keep entries
small and readable: a stable key, client-facing `id`, and the upstream
references that actually exist for `hf`, `ollama`, and `llama`.

Do not add a second serving catalog, generated lock file, runtime-image matrix,
or command generator. Container image, command, accelerator, port, lifecycle,
and engine-specific flags remain in each service definition. The model catalog
describes obtainable model data; it does not construct runtimes.

The expanded form of `hf` is intentionally narrow:

```nix
hf = {
  ref = "owner/repository";
  revision = "release-tag"; # optional
  include = ["MTP/draft.gguf"]; # optional
};
```

A string remains shorthand for `{ ref = "..."; }`. `include` is useful for a
published draft, projector, adapter, or other auxiliary file without caching
every quant in a conversion repository. Revisions may be branches, tags, or
commits. Moving revisions are resolved by Hugging Face during each prefetch,
just as image tags are resolved by the image pre-pull.

Model-bound auxiliary weights live under their model, using short names that are
meaningful only in that model's scope:

```nix
qwen38-27b = {
  id = "qwen3.8:27b";
  hf = "Qwen/Qwen3.8-27B";
  artifacts = {
    f16-mmproj.hf = {
      ref = "unsloth/Qwen3.8-27B-GGUF";
      include = ["mmproj-F16.gguf"];
    };
    q4-mtp.hf = {
      ref = "unsloth/Qwen3.8-27B-GGUF";
      include = ["MTP/mtp-Qwen3.8-27B-Q4_0.gguf"];
    };
  };
};
```

Nested artifacts have no client-facing `id`: they are downloadable units of
their parent, not independently served models. Nested artifacts currently use
Hugging Face sources only; add a backend adapter before accepting another source
shape. A genuinely shared or unattached unit may remain a top-level entry with
`internal = true`; those entries remain addressable by backend prefetch policy
while staying out of client model maps and default UI pinning.

## Catalog key convention

Catalog attribute names use:

```text
<model-name>-<target-size>[-<encoding>][-<variant>]
```

- `model-name` includes identity-defining architecture or release variants, such
  as `qwen38-flash-next`; do not move `flash-next` behind the encoding.
- `target-size` is the served model's total parameter count. For sparse MoE
  models, append active parameters as `-a<size>`, such as `gemma4-26b-a4b` or
  `125b-a6b`.
- `encoding` appears when the entry identifies one exact encoded artifact. It is
  omitted when a single logical entry intentionally maps to different native HF,
  Ollama, and GGUF artifacts.
- `variant` is last. For model-bound auxiliary weights this convention applies
  to the short key below `artifacts`, such as `q4-mtp`, `f16-mmproj`, or
  `bf16-eagle3`. Primary weights have no redundant `model` suffix.

Normalize sizes and encodings for readable Nix keys without changing upstream
repository names, file names, runtime aliases, or client-facing IDs:

```text
0.1B         -> 100m
0.8B         -> 800m
Q4_K_M       -> q4-km
Q4_K_S       -> q4-ks
Q4_K_XL      -> q4-kxl
UD-Q4_K_XL   -> ud-q4-kxl
Q4_0         -> q4
Q8_0         -> q8
MXFP4        -> mxfp4
```

Only the default `_0` suffix is dropped for `Q4_0` and `Q8_0`; meaningful scheme
revisions remain explicit. Fractional billions use an exact whole-million form
instead of a decimal placeholder. Top-level examples include `qwen38-27b-fp8`
and `gemma4-12b`; nested examples include `gemma4-12b.artifacts.bf16-eagle3` and
`qwen38-27b.artifacts.q4-mtp`.

Exceptionally large model families may remain as clearly commented catalog
blocks while inactive. Comment the complete family, including alternate
encodings and nested artifacts, so it cannot enter admission or prefetch by
accident and can later be restored as one reviewed unit.

## Variants and concurrency

Give independently servable weight sets distinct top-level catalog keys: BF16,
FP8, and GGUF Q-types may run concurrently in several service instances. Group
an external draft, projector, adapter, or architecture-specific speculative unit
under its sole parent model instead of inventing another global model.

Runtime-only behavior is not another model artifact:

- N-gram speculation has no weights and stays in the vLLM/SGLang command.
- Built-in MTP uses the base repository when the engine reads its native MTP
  tensors; only separately published MTP weights need a nested artifact.
- DFlash, DSpark, Eagle, and similar methods get nested artifacts only when they
  publish auxiliary weights.
- Served aliases and runtime flags stay explicit in the service that launches
  the backend.

KV-cache encoding is runtime state, not model identity. Ollama keeps its
process-wide `OLLAMA_KV_CACHE_TYPE`. vLLM, SGLang, and llama.cpp choose q8 by
their normal dynamic/service parameters and use f16 only where a selected model
requires it. The catalog never fixes KV-cache encoding.

## Candidate-generation plan

The NixOS candidate carries `share/ai/model-prefetch.json` for inspection and
`ai-model-prefetch-all` when the plan is non-empty. The executable embeds that
candidate plan; deploy engines invoke only the candidate executable and do not
reconstruct or redirect its plan. Both engines use one ordering:

```text
distribute candidate -> prepare target -> generation admission -> image pull -> model prefetch -> activation
```

Target preparation repairs failed-unit and user-manager state; it is not model
or service-policy admission. The generation-admission stage runs the current
generation's authoritative dispatcher against the candidate before any
candidate-owned acquisition. Activation repeats the same admission while holding
the host-local activation lock, closing the race between the early fail-fast
check and the switch.

The first normal deployment that introduces generation authority is the narrow
exception: there is no current dispatcher allowed to approve candidate-owned
acquisition, and the target may not approve itself early. Both engines treat
that condition as an explicit deferral, skip image and model acquisition, and
continue to activation, where the target's existing first-interface pre-switch
checks establish authority. Post-activation image/model owners then converge.

The plan has three adapters:

- Ollama entries are derived from the already-resolved Ollama selection and try
  the current deployment endpoints.
- llama.cpp entries are derived from the union of each runtime's deployment
  filters and ask a current non-stopped router for that runtime to cache each
  exact HF reference once. Manual deployments remain eligible because they may
  already be running; a runtime with only stopped deployments emits no warmup
  entries.
- Hugging Face entries come from `services.ai.backends.hf.prefetch`, use the
  catalog's `hf` references, and run `hf download` against the same `HF_HOME`
  mounted by vLLM/SGLang.

The pure `prefetch.nix` resolver owns the bool/list/expanded selection algebra
and produces exact downloadable units plus diagnostics. The NixOS module owns
only configuration identity, assertions, and candidate integration. Invalid
configuration never produces a malformed HF plan entry.

Prefetch configuration stays with the backend that performs it:

```nix
services.ai.backends = {
  hf = {
    cacheDir = "/var/lib/example/ai/huggingface";
    user = "example";
    prefetchDefaults.artifacts = true;
    prefetch = {
      qwen38-27b = {
        base = false;
        artifacts = ["q4-mtp"];
      };
      gemma4-12b = ["bf16-dflash" "bf16-eagle3"];
      qwen38-27b-fp8 = true;
    };
  };
  ollama.prefetch = true;
  llamaRouter.prefetch = true;
};
```

The concise forms cover common cases: `true` downloads the base and every nested
artifact by default, a list downloads the base plus exactly the named artifacts,
`[]` means base only, and `false` disables an inherited entry. Set
`prefetchDefaults.artifacts = false` when nested artifacts should be globally
opt-in. An expanded selection controls the two dimensions independently:

```nix
qwen38-27b = {
  base = false;
  artifacts = ["f16-mmproj" "q4-mtp"];
};
```

Within the expanded form, `artifacts = true` selects all nested artifacts,
`false` selects none, a list selects an exact subset, and omitted or `null`
inherits the backend-wide default. This preserves concise declarations while
making artifact-only acquisition explicit and avoiding an unnecessary
base-repository download. Modules that compose one model selection must use the
expanded form: boolean and list shorthands are intentionally atomic Nix option
values.

An expanded selection must resolve to at least one base or nested unit;
`{ base = false; artifacts = false; }` is rejected instead of silently doing
nothing. Use the literal `false` to disable an inherited selection. HF prefetch
is deliberately independent from `services.ai.models`: it may stage a future
model or acquire an auxiliary artifact, but it never admits or serves one.

The first two are best-effort because a cold host, inactive manual backend, or
port transition may leave no old endpoint. A llama.cpp warmup accepts an
already-cached or accepted cache request and returns; it does not poll for an
hour. Ollama and llama.cpp share one finite best-effort phase budget. Short
llama.cpp status checks and cache submissions run before synchronous Ollama
pulls, so one long transfer cannot prevent the lightweight requests from being
attempted. Existing post-activation reconcilers remain the reliable adoption
path. Hugging Face entries are required because they download directly and do
not depend on a running old backend, but they also have a finite required-phase
deadline. Defaults are 300 seconds for the complete best-effort phase, five
seconds to connect each HTTP request, and 21,600 seconds for the complete
required HF phase. The runner exposes matching `AI_MODEL_PREFETCH_*` environment
overrides for bounded operational testing; normal deploys use the defaults.

The runner validates the complete JSON array and every backend-specific entry
before creating directories or contacting a service. An empty endpoint list is a
malformed adapter entry, not a best-effort outage. A malformed plan, include
filter, endpoint, owner identity, API response, or token path fails explicitly;
shell process-substitution failures cannot silently turn a filtered download
into a full-repository download. Best-effort controls acquisition failure
policy, not schema validity or unbounded activation latency. One accepted and
rejected path corpus is exercised against the independent Nix, jq, and Python
validators so their trust boundaries stay separate without semantic drift.

llama.cpp prefetch validates that a successful POST returns a JSON object
without an error. The eventual reconciler separately verifies backend state;
this stricter preactivation acknowledgement prevents a malformed proxy response
from being reported as a successful warmup.

Prefetch is additive. It never deletes cache data, writes reconciler ownership
manifests, changes model selection, starts a backend, or claims accelerator
residency. The existing Ollama and llama.cpp reconcilers remain the only
retirement authority.

A deploy dry run performs no image pull or model acquisition in either fleet
engine. Shell Nixbot reports both skipped pre-activation actions; native fleet
sends every candidate-side deployment action through its mutation-aware host
runtime, which suppresses those effects in dry-run mode.

## Credentials

`services.ai.backends.hf.user = null` inherits the compose stack user. Whenever
`cacheDir` is configured, it must be a canonical absolute non-root path without
empty/dot components and with portable `[A-Za-z0-9._+,:=@-]` components, and its
resolved user and primary group must be declared in the candidate system. This
keeps the steady-state `0750` tmpfiles rule unambiguous even when no direct
prefetch is selected. A non-empty direct-HF selection requires that cache plus
fixed numeric IDs in the runner's supported `0..2147483647` range. The plan
records the user name, UID, group name, and GID. Before any required entry
mutates the filesystem, the runner validates both name-to-ID and ID-to-name
mappings for the complete required phase.

The candidate embeds a small cache-preparation helper. It walks from `/` through
directory descriptors with no-follow semantics, creates the final-owned child
inside a root-private random `0700` staging directory, publishes that completed
child by an atomic no-replace rename, and verifies that the final path still
names that inode. Concurrent creators therefore observe either no path or a
fully initialized directory, never a published `0700` or root-owned leaf; the
target owner cannot access its prepared child before publication. Existing
leaves are never repaired: any owner, group, mode, type, or symlink conflict
fails explicitly. After the exact `0750` leaf is ready, the runner drops
privileges numerically and performs all network and cache writes as the
candidate owner. This allows a host's first generation to prefetch before the
candidate account and steady-state tmpfiles declarations are activated without
performing privileged shell writes through a user-controlled parent.

Configured HF, Ollama, and per-runtime llama.cpp storage roots must be pairwise
non-overlapping by path component; equality and ancestor/descendant layouts are
both rejected. The conventional `/var/lib/<stack>/ai` tmpfiles parent is emitted
only when a rendered storage leaf is strictly below it. If a single cache owns
that exact path, its leaf rule is the only rule, and a stack with no managed AI
storage receives no AI tmpfiles rule.

`services.ai.backends.hf.tokenFile` is an optional absolute non-root runtime
path subject to the same path-shape checks. Before any required cache is created
or download begins, every configured file is read and format-validated under the
exact numeric cache-owner identity, with supplementary groups cleared. It must
already exist on the target with exactly one non-empty, whitespace-free line and
cannot be introduced only by the candidate activation. The download subprocess
clears ambient `HF_TOKEN` and legacy `HUGGING_FACE_HUB_TOKEN`, then sets only
the validated file value as `HF_TOKEN`; token contents are absent from the Nix
store, plan, logs, and process arguments. A gated repository should therefore
declare `tokenFile` and provision that file through the host's pre-activation
secret path. Public repositories need no token, and credentials already stored
inside the configured cache may still be used when no file is set.

Deploy dry runs preserve the same stage shape but never realize or distribute a
remote-build closure, create deployment markers, contact a model or image
source, or activate a generation. They print the skipped distribution and
candidate-acquisition stages plus the activation command for inspection.

Consumer projections use `hfSourcesById`: public entries with a valid HF source
become served-ID to `{ ref, revision }` mappings, while valid Ollama- or
GGUF-only public entries are skipped. `hfSourceForId` gives consumers one clear
failure when their selected model has no HF source, and the compatibility
`hfCatalogById` view retains reference strings. vLLM/SGLang consume the
structured source so serving and prefetch use the same revision. The whole
catalog remains fail-closed, so a present but malformed HF source is still an
evaluation error.

## Cross-repository boundary

The catalog, module, runner, deploy integration, and tests are shared
byte-for-byte between Abird and Pvl. Host model selections, HF cache paths,
users, tokens, and explicit runtime commands remain host-owned.
