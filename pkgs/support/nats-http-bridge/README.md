# nats-http-bridge

Bridge a list of core NATS or JetStream subscriptions into HTTP calls.

The package ships one binary:

- `nats-http-bridge`

## Behavior

Each configured route binds one NATS subject to one HTTP endpoint.

- `core` + `push`: call the HTTP endpoint and forget the response.
- `core` + `request-response`: call the HTTP endpoint and send the HTTP
  response body back on the NATS reply subject.
- `jetstream` + `push`: call the HTTP endpoint, `ACK` on `2xx`, otherwise
  delayed-`NAK` retryable failures or `TERM` obvious poison `4xx` failures.
- `jetstream` + `request-response`: call the HTTP endpoint, `ACK` on `2xx`,
  then publish the HTTP response body on the NATS reply subject. Non-`2xx`
  responses are retried with delayed `NAK` when they look transient, or
  `TERM`ed when they look like obvious poison `4xx` failures, and are not
  replied to.

JetStream routes auto-create or reuse a durable pull consumer. The stream must
already exist.

After the config has passed validation and the process is running, NATS and
JetStream operational failures are non-fatal. The bridge keeps the last loaded
config in memory and retries route setup, subscriptions, stream lookup,
consumer reconciliation, fetches, and receives with exponential backoff.

## Quick start

Example `bridge.yaml`:

```yaml
routes:
  - name: orders-core-push
    subject: orders.created
    mode: push
    http:
      url: http://127.0.0.1:8080/orders
      method: post
    transport:
      kind: core

  - name: orders-js-reply
    subject: orders.lookup
    mode: request-response
    http:
      url: http://127.0.0.1:8080/orders/lookup
      method: post
    transport:
      kind: jetstream
      stream: orders
      consumer: orders_http_bridge
      ack_wait_secs: 30
      max_ack_pending: 1
      fetch_batch: 1
      nak_delay_secs: 30
```

Run it:

```bash
cargo run -- --config ./bridge.yaml
```

Build from Nix:

```bash
nix-build default.nix
./result/bin/nats-http-bridge --config ./bridge.yaml
```

## CLI

```text
nats-http-bridge --config <path> [--server <url>] [--tls <bool>] \
  [--ca-cert <path>] [--client-cert <path>] [--client-key <path>] \
  [--http-timeout-secs <seconds>] [--log-filter <filter>] [--check-config]
```

Defaults:

- NATS server: `nats://127.0.0.1:4222`
- HTTP timeout: `30` seconds
- HTTP method per route: `POST`
- Route mode per route: `push`
- Route transport per route: `core`

Use `--check-config` to parse and validate the config without connecting to
NATS. The package also exports `passthru.validateConfig` and
`passthru.mkConfigText` so Nix-generated bridge configs can fail during
evaluation/build before deployment.

## Config schema

Each `routes` list entry supports:

- `name`: optional log label.
- `subject`: NATS subject to subscribe to.
- `mode`: `push` or `request-response`.
- `http.url`: target HTTP endpoint.
- `http.method`: `get` or `post`.
- `transport.kind`: `core` or `jetstream`.

JetStream-only transport keys:

- `stream`: existing JetStream stream name.
- `consumer`: optional durable consumer name. If omitted, the tool derives one
  from the route.
- `ack_wait_secs`: optional ack timeout passed to the durable consumer.
- `max_ack_pending`: optional durable consumer `max_ack_pending`.
- `max_deliver`: optional durable consumer `max_deliver`.
- `fetch_batch`: optional pull batch size, default `1`.
- `nak_delay_secs`: optional delayed retry interval for retryable JetStream
  failures, default `30`.

## Notes

- For `GET` routes, the NATS payload is ignored.
- For `POST` routes, the NATS payload is sent as the HTTP request body.
- Core NATS request-response requires a NATS reply subject on the inbound
  message. If there is no reply subject, the message is logged and skipped.
- JetStream request-response follows the requested order: on `2xx`, the message
  is `ACK`ed first and the HTTP response body is then published to the reply
  subject.
- JetStream retry policy:
  - `429` and `5xx`: delayed `NAK`
  - network / timeout errors: delayed `NAK`
  - clear poison cases like `400` / `404` / `422`: `TERM`, not retry
  - `max_deliver` remains the hard cap for retryable failures
- JetStream request-response reads the response subject from the
  `X-Nats-Http-Bridge-Reply-Subject` header. The normal NATS reply field on a
  JetStream consumer message is reserved for JetStream acknowledgements, so a
  streamed requester should publish with that header set to the inbox it wants
  the bridge response sent to.
