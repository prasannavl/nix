# Pi model context windows for custom providers (2026-09)

## Symptom

Pi auto-compacted an `ollama-cloud` DeepSeek V4.1 Flash session far too early,
and `pi --list-models` reported `128K` context.

## Root cause

For models declared directly in `~/.pi/agent/models.json`, Pi fills unset fields
with defaults (`dist/core/provider-composer.js`):

```js
contextWindow: definition.contextWindow ?? 128000,
maxTokens: definition.maxTokens ?? 16384,
```

`ollama-cloud` is a user-defined provider, and its hand-written model entries
carried only `id`/`reasoning`/`input`, so every model silently got 128k.
Compaction triggers per `docs/compaction.md` at
`contextTokens > contextWindow - reserveTokens` (`reserveTokens` default 16384),
i.e. ~111.6k.

## Discovery is metadata-poor for Ollama Cloud

`pi-models-discovery` reads providers marked `"discoverModels": true` and GETs
`{baseUrl}/models`. For `ollama-cloud` that is `https://ollama.com/v1/models`,
which returns only `id`/`object`/`created`/`owned_by` — **no `context_window`
and no `max_tokens`**. The extension then falls back to
`contextWindow ?? 1_000_000`, `maxTokens ?? 65_536`, `reasoning: true`, and
`input: ["text","image"]` for every entry.

Real metadata exists only under `POST https://ollama.com/api/show`, which
reports a `<family>.context_length` and a `capabilities` list. Contexts across
the 20 models span 131072 (`gpt-oss:*`) to 1048576 (`glm-5.3`,
`deepseek-v4.1-flash`, …), so a bare `discoverModels: true` would over-declare
many models by up to 8x and suppress compaction until ~984k.

## Solution

Enable discovery on `ollama-cloud` and correct the defaults with
`modelOverrides`, which `provider-composer.js` applies as the topmost user layer
(after discovery and extension model replacement):

```json
"ollama-cloud": {
  "baseUrl": "https://ollama.com/v1",
  "api": "openai-completions",
  "apiKey": "...",
  "discoverModels": true,
  "modelOverrides": {
    "gpt-oss:20b": { "contextWindow": 131072, "input": ["text"] },
    "glm-5.1": { "contextWindow": 202752, "input": ["text"] },
    "glm-5.3": { "input": ["text"] }
  }
}
```

Overrides are generated from `/api/show`:

- `contextWindow` only when the reported `context_length` differs from the
  discovery default 1048576;
- `input: ["text"]` only when `capabilities` lacks `vision`.

All 20 models advertise `thinking`, so the discovery `reasoning: true` default
is correct. The `maxTokens` default 65536 is left as-is; Ollama accepts it and
caps internally (verified against `gpt-oss:20b`, `glm-5.1`, `minimax-m2.7`,
`gemma4:31b`).

The hand-written `models` array is retained in `models.json` as the extension's
offline fallback when discovery cannot fetch.

## Verification

`pi --list-models`:

```text
provider        model                    context  max-out  thinking  images
ollama-cloud    deepseek-v4.1-flash      1M       65.5K    yes       yes
ollama-cloud    glm-5.1                  202.8K   65.5K    yes       no
ollama-cloud    gpt-oss:20b              131.1K   65.5K    yes       no
```

Discovery caches to `~/.pi/agent/extensions/pi-models-discovery/cache.json`
(fingerprint = `baseUrl+api+apiKey+headers+compat`);
`/config:model-discovery-refresh` forces a re-fetch.

Applied on `pvl-l5` and `pvl-a1` (backups `models.json.bak-disc-<ts>`).

## Files

- `~/.pi/agent/models.json` (out-of-repo user state, not committed)
