# gap3-api-ingest scaffold and service split

- Date: 2026-04-08
- Scope: `pkgs/gap3-api-ingest`, `pkgs/manifest.nix`

## Decision

Create `pkgs/gap3-api-ingest` as a Rust child flake using Axum for HTTP ingress
and NATS JetStream as the durability boundary for accepted ingest requests.

## Applied shape

- `POST /v1/ingest/messages` accepts a simple JSON envelope with source, tenant,
  event, and arbitrary payload fields.
- Acceptance means the event was published to a JetStream-backed subject and the
  publish ack was received.
- `GET /healthz` is liveness-only.
- `GET /readyz` checks both PostgreSQL and the configured JetStream stream.
- Defaults target the repo-local services on `127.0.0.1:4222` and
  `127.0.0.1:5432`.
- The package is wired into the root package manifest as `gap3-api-ingest`.

## Existing Python service

- `chat-intelligence/py/whatsapp_ingest` already covers webhook verification,
  WhatsApp payload parsing, inbound-message extraction, sender lookup in
  Supabase, and initial routing classification for text vs media.
- That service is currently stateless and does not yet publish to NATS, persist
  raw events, fetch media, run LLM work, or materialize vertical outputs.

## Service split from the RFC

- Existing service: `whatsapp_ingest` can remain the protocol-specific webhook
  adapter if we want to preserve its WhatsApp model parsing and sender-lookup
  logic.
- New service 1: `gap3-api-ingest` is the durable ingress boundary in the repo
  and should own authenticated intake plus JetStream publishing.
- New service 2: raw event persistence worker to write accepted inbound events
  into Postgres.
- New service 3: normalization worker to convert raw WhatsApp payloads into
  canonical internal message events.
- New service 4: media detector / media scheduling worker for attachments that
  require fetch.
- New service 5: media fetch worker to download WhatsApp media and store it in
  object storage.
- New service 6: LLM preprocessor to create prompt-ready units, dedupe keys, and
  cache lookup inputs.
- New service 7: LLM worker to execute extraction and summarization jobs and
  persist results.
- New service 8: trading vertical service to consume normalized and enriched
  events and own domain workflows.
- New service 9: quote extractor inside the trading vertical, if kept separately
  from the main vertical orchestrator.
- New service 10: reconciliation worker inside the trading vertical for price
  merging and consistency rules.
- New service 11: sheet projector / exporter for Excel or spreadsheet
  materialization.
- New service 12: trading read API or dashboard backend for downstream
  consumption.

## Recommended near-term packaging

- Keep `whatsapp_ingest` as the WhatsApp-specific adapter and have it forward
  canonical ingest envelopes into `gap3-api-ingest`, or move its parsing logic
  into Rust later once the event contract stabilizes.
- Treat services 2 through 7 as one deployable `gap3-core-workers` process at
  first, implemented as multiple JetStream consumers inside one binary, to keep
  operational overhead low.
- Treat services 8 through 12 as one deployable `gap3-vertical-trading` process
  at first, with internal worker loops for extraction, reconciliation, and
  projection.

## Initial deployable count

- If you optimize for clear boundaries today: 12 services total, with 1 already
  present in Python and 11 still to build.
- If you optimize for minimal operations first: 4 deployables total:
  `whatsapp_ingest`, `gap3-api-ingest`, `gap3-core-workers`,
  `gap3-vertical-trading`.

## Follow-up

- Add a durable ingest schema aligned with the concrete WhatsApp webhook shape.
- Introduce explicit auth and signature verification before exposing the
  endpoint publicly.
- Decide whether stream creation should stay implicit at startup or move into
  infra provisioning.
