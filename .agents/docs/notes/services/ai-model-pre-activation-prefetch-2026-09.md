# AI Model Pre-Activation Prefetch

## Implemented boundary

Candidate generations may contain `share/ai/model-prefetch.json` and
`ai-model-prefetch-all`. The runner embeds its candidate plan, so Nixbot and the
native host manager need only invoke that candidate executable. Both deploy
engines distribute the closure, pass pre-switch admission, pre-pull images,
prefetch models, and then activate.

The implementation deliberately reuses the original model catalog and backend
selection:

- selected Ollama tags are warmed through a current Ollama API;
- selected GGUF references are warmed through the matching named llama.cpp
  runtime;
- a catalog-keyed `services.ai.backends.hf.prefetch` attrset is downloaded with
  `hf download` into the same `HF_HOME` used by vLLM/SGLang.

No generated artifact lock or separate serving catalog is tracked. Hugging Face
resolves the configured branch, tag, or commit during prefetch and manages its
own resumable content-addressed cache.

## Failure policy

Ollama and llama.cpp warming is best-effort because inactive manual backends and
cold hosts can have no pre-activation endpoint. Stopped llama.cpp deployments
emit no warmup entries; manual deployments remain eligible because they may
already be running. Their shared phase has a finite total budget. Lightweight
llama.cpp cache requests run before synchronous Ollama pulls, and llama.cpp
returns after a cache hit or accepted request rather than polling for a
completed download. Their existing reconciler still runs after activation.
Direct Hugging Face downloads are required and block activation on failure,
within a finite required-phase deadline.

The runner validates the complete plan, every required owner identity, and every
configured token under that exact numeric identity before mutation. Direct HF
entries carry the cache owner's candidate user name, UID, group name, and GID. A
candidate-embedded helper traverses directory descriptors without following
symlinks, fully initializes each leaf inside a root-private staging directory,
atomically publishes it without replacement, verifies final inode reachability,
and then lets the runner drop privileges numerically. Existing cache owner,
group, mode, type, and symlink conflicts fail explicitly; no existing cache is
recursively repaired. A shared path corpus keeps the independent Nix, jq, and
Python safety checks semantically aligned.

An HF `cacheDir` is valid independently of prefetch selection: it must be a
canonical safe absolute non-root path and have a candidate-declared owner and
primary group. A non-empty HF selection additionally requires the cache and
fixed numeric IDs in the runner's supported range. Invalid configuration fails
through a Nix assertion and cannot emit a malformed plan entry.

HF, Ollama, and each llama.cpp runtime must use pairwise non-overlapping cache
roots. The shared stack AI tmpfiles parent appears only when a rendered cache is
strictly nested below it, so stack-only hosts gain no AI storage and a cache at
the exact parent path receives only its own leaf rule.

The runner only acquires data. It does not start services, alter runtime
commands, set KV-cache types, adopt ownership, prune, or retire models. Deploy
dry runs do not realize or distribute remote-build closures, create deploy
markers, or invoke image/model acquisition in either fleet engine.

## Host adoption

`abird-srv` explicitly prefetches `gemma4-26b-a4b` through
`services.ai.backends.hf` into `/var/lib/abird/ai/huggingface`, matching its
existing vLLM and SGLang mounts. Pvl needs no HF host-policy declaration: its
existing `models` and named runtime selection automatically produce Ollama and
llama.cpp warmup entries.

The shared active catalog records Qwen 3.8 BF16/FP8 and GGUF MTP/projector
sources plus Gemma DFlash, DSpark, and Eagle auxiliary repositories. DeepSeek
V4.1 Flash and the complete Qwen 3.8 Flash-Next 125B family remain together as
commented catalog blocks for later activation. Model-bound auxiliary weights are
nested under their parent and included automatically for a `true` HF selection
unless `prefetchDefaults.artifacts = false`; explicit artifact lists select an
exact subset in addition to the base. The expanded per-model form can set
`base = false` to fetch only selected nested artifacts and is the required form
when several Nix modules compose one selection. A literal `false` disables an
entry; an expanded form selecting neither base nor artifacts is rejected.
Prefetch intentionally remains independent from model admission so it can stage
future or auxiliary data. Runtime-only N-gram and KV-cache flags remain in
service configuration.

Nested artifacts are intentionally HF-only until another acquisition adapter is
implemented. A configured `tokenFile` must use the same safe absolute path shape
and be provisioned and readable by the cache owner before activation; it cannot
depend on candidate activation. The download subprocess clears both current and
legacy ambient Hugging Face token variables before installing that explicit
credential. Public repositories need no token. The consumer-facing
`hfSourcesById` projection preserves both repository and revision, skips valid
public entries without HF sources, and still rejects a malformed declared HF
source. Checked source lookup lets a vLLM/SGLang consumer fail clearly for a
non-HF default and prevents serving from drifting from a prefetched revision.
