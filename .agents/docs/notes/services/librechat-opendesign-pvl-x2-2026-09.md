# LibreChat and OpenDesign on pvl-x2, 2026-09

## Decision

`pvl-x2` gains two self-hosted apps ported from the abird stack:

- **LibreChat** — `hosts/pvl-x2/services/librechat.nix`, port `18094`, domain
  `librechat.p7log.com`.
- **OpenDesign** — `hosts/pvl-x2/services/opendesign.nix` plus the newly ported
  `pkgs/ext/opendesign/` package, port `18096`, domain `design.p7log.com`.

Both follow the pvl host-service pattern: they read their port and domain from
`stack.serviceRegistry` (`registry.portFor`, `registry.domains`,
`registry.urlPublicFor`), declare `exposedPorts.http.nginxHostNames`, and use
the registry entries added to `lib/stacks/pvl-registry.nix`.

## Adaptations from abird

The abird originals (`hosts/abird-corp/services/{librechat,opendesign}.nix`) are
coupled to abird-only infrastructure and were changed as follows:

| Concern     | abird                                                  | pvl-x2                                                          |
| ----------- | ------------------------------------------------------ | --------------------------------------------------------------- |
| Auth        | Kanidm OIDC (`abird-id`, `OPENID_*`, client secret)    | local email/password; no IdM on pvl                             |
| AI endpoint | `ai.mkApi registry` against `abird-srv`                | `http://host.containers.internal:12434` (`ollama-rocm`)         |
| Model list  | `ai.modelCatalog` minus embedding                      | Ollama-tagged models from `config.services.ai`, minus embedding |
| Storage     | `/var/lib/abird/...`                                   | `/var/lib/pvl/...`                                              |
| Exposure    | `useUpstreamCsp` + registry subnet + Cloudflare tunnel | `nginxHostNames` only; no tunnel hostnames yet (LAN/tailnet)    |
| Secrets     | Kanidm age secret + generated MEILI/CREDS/JWT          | generated MEILI/CREDS/JWT only                                  |

LibreChat uses the `custom` endpoint (OpenAI-compatible) with
`apiKey: "ollama"`. The model list excludes entries without an `ollama`
reference (so `bonsai-2-27b`, served only by the PrismML llama.cpp runtime, is
not offered).

OpenDesign runs the `pkgs.opendesign` image with a `managedByokProvider`
override (`pvl-ai`, protocol `ollama`, model `qwen3.5:4b`) and an in-container
loopback proxy that bridges the app's fixed `127.0.0.1:11434` to the host Ollama
via `PVL_OLLAMA_BASE_URL`.

## Package ownership

`pkgs/ext/opendesign/{default.nix,sources.nix,managed-byok-provider.patch}` is a
verbatim copy of the abird unit:

- `sources.nix` is `github-tags` on `nexu-io/open-design`, pinned to `0.23.0`
  (`c2aba14421c7b6ee1ace4bee3636d3bf64ee1fa0`), with a pinned Node 24.18.0 build
  and its OpenSSL CCM compatibility patch.
- Registered in `pkgs/manifest.nix`, so it is exposed as `pkgs.opendesign` and
  discovered by `scripts/update.sh --report` through `pkgs/ext/*/sources.nix`.
- No `update.sh`; the source report tracks the pin.

The first build is heavy (pnpm dependency fetch plus a native `better-sqlite3`
rebuild) and is not exercised by eval-only checks.

## Storage and secrets

- `/var/lib/pvl/librechat` (owned root for the parent, `1000:1000` for the
  `images`, `uploads`, `logs`, `skill`, `mongodb`, and `meilisearch` leaves).
- `/var/lib/pvl/opendesign` (owned `1001:1001`).
- `librechat.env` is generated on first start by `preStart` (`MEILI_MASTER_KEY`,
  `CREDS_KEY`, `CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET`) and never
  committed.

## Consumer AI endpoint lists

All AI consumers list the AI device classes in **ROCm, NVIDIA, CPU** order so
the CPU fallback is always last:

- **Open WebUI** (`pvl-a1`, `pvl-l5`, `pvl-x2`): `OLLAMA_BASE_URLS` carries the
  Ollama device classes in that order, and `OPENAI_API_BASE_URLS` /
  `OPENAI_API_KEYS` carry the llama.cpp device classes as OpenAI-compatible
  `/v1` endpoints via `host.containers.internal` (ROCm `12000`, NVIDIA `13000`,
  CPU `11000`). The `pvl-x2` instance was also corrected from the legacy
  singular `OLLAMA_BASE_URL` on `127.0.0.1` to the plural `OLLAMA_BASE_URLS` on
  `host.containers.internal`.
- **LibreChat** (`pvl-x2`): three `endpoints.custom` entries — Ollama,
  `Pvl llama.cpp ROCm`, and `Pvl llama.cpp CPU` — each with both a
  `models.default` array and `fetch: true`, with CPU last. `pvl-x2` has no
  NVIDIA class, so it is omitted.
- **OpenDesign** (`pvl-x2`): only one `managedByokProvider` is supported by the
  package, so it stays on the Ollama endpoint; it cannot list multiple backends.

The lists are built directly from each backend's `ports` projection, which
preserves the `services/ai.nix` deployment order (ROCm, NVIDIA, CPU). The order
contract is documented at the top of `backends` in each host's `ai.nix`; no
per-consumer device ranking is needed.

## Exposure

LAN/tailnet only for now: nginx proxy vhosts are generated, but `cloudflare`
tunnel hostnames are intentionally not declared. Adding them later is a
follow-up: add `tunnels` (or `cfTunnelNames`) on the exposed port and the
matching external DNS record.

## Deploy finding: LibreChat custom endpoint requires `models.default`

The first `pvl-x2` deploy failed health checks: `pvl-librechat-verify.service`
went failed and `pvl-librechat-ready.target` stayed inactive. The `api`
container exited 1 with `Invalid custom config file at /app/librechat.yaml` /
`endpoints.custom[1].models.default: expected array, received undefined`.

LibreChat validates every `endpoints.custom` entry and requires a
`models.default` array; `fetch: true` alone is not enough. The llama.cpp entries
now carry `models.default` (the same alias list as the Ollama endpoint, since
the router serves the same model aliases) plus `fetch: true`. The
mongo/meilisearch containers were healthy; only the api config was rejected.

Symptom pattern to remember: a compose `*-verify.service` failure with an
`*-ready.target` inactive and a healthy-looking main service usually means the
main container exited right after start. Check `podman ps -a` and the app
container logs, not just the unit status.

## Validation

- `pvl-x2` evaluates with zero failed assertions.
- `librechat` renders with `18094:3080`, `DOMAIN_CLIENT`/`DOMAIN_SERVER` =
  `https://librechat.p7log.com`, and the Ollama base URL
  `http://host.containers.internal:12434/v1`.
- `opendesign` renders with `18096:7456` and
  `OD_ALLOWED_ORIGINS=https://design.p7log.com`.
- `nginx-proxy-vhosts` includes `librechat-http` and `opendesign-http`, and the
  nginx instance `wants` both backends.
- `nix run .#lint` passes.

## Follow-ups

- Add Cloudflare tunnel hostnames and DNS for both apps when public access is
  wanted.
- Decide whether LibreChat registration stays open after the first account
  (`ALLOW_REGISTRATION` is currently `true`).
- Consider a dedicated role (`services.ai.roles.main`) on `pvl-x2` so OpenDesign
  and LibreChat default to an explicit model instead of the `qwen35-4b`
  fallback.
