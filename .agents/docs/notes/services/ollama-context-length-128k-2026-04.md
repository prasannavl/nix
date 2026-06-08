# Ollama Context Length 128k 2026-04

`pvl-a1` now sets `OLLAMA_CONTEXT_LENGTH=131072` for both the ROCm-backed
`ollama` instance and the disabled-by-default `ollama-nvidia` instance in
`hosts/pvl-a1/services/ollama.nix`.

Reason: Open WebUI was sending prompts larger than the prior effective 4k
context limit, which caused Ollama to log `truncating input prompt` warnings and
drop prompt content before inference.

Operational tradeoff: larger context windows materially increase VRAM and memory
pressure. If model loading or performance regresses, reduce the default or set
`num_ctx` per request instead of relying on a global 128k default.
