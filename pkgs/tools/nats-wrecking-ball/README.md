# nats-wrecking-ball

NATS stress tooling with one default orchestrator plus standalone producer and
consumer binaries.

## Binaries

- `nats-wrecking-ball`: runs the full test, starts one producer plus N
  consumers, and prints combined totals.
- `nats-wrecking-ball-producer`: standalone producer.
- `nats-wrecking-ball-consumer`: standalone consumer.

## Quick start

Run the full orchestrated test:

```bash
cargo run --bin nats-wrecking-ball -- \
  --mode fanout \
  --consumers 2 \
  --producer-rate 100000 \
  --producer-duration 30s
```

On `gap3-rivendell`, the installed package defaults to the host-local NATS mTLS
setup with `--profile gap3`:

```bash
nats-wrecking-ball --profile gap3 --mode fanout --consumers 2 --producer-rate 100000 --producer-duration 30s
```

Build and run from Nix:

```bash
nix-build default.nix
./result/bin/nats-wrecking-ball --mode fanout --consumers 2 --producer-rate 100000 --producer-duration 30s
```

## Orchestrator examples

Fanout, unlimited producer, two consumers:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --producers 1 \
  --consumers 2 \
  --producer-duration 30s
```

Fanout, fixed rate:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --producers 1 \
  --consumers 2 \
  --producer-rate 100000 \
  --producer-duration 30s
```

Fanout, three separate producers and two consumers:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --producers 3 \
  --consumers 2 \
  --producer-rate 100000 \
  --producer-duration 30s
```

Fanout, fixed message count:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --consumers 2 \
  --producer-count 1000000
```

Queue, three consumers sharing one work queue:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode queue \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s
```

Request/reply, three consumers, producer timeout tuning:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode req-reply \
  --consumers 3 \
  --producer-rate 10000 \
  --producer-duration 30s \
  --request-timeout-ms 2000
```

JetStream queue strict:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-strict \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --stream wrecking_ball \
  --consumer wrecking_ball_workers
```

JetStream queue concurrent:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-concurrent \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s
```

JetStream queue concurrent, consume without acking:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-concurrent \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --jetstream-ack-mode none
```

JetStream replay, every consumer replays the retained stream:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-replay \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s
```

JetStream strict exactly-once queue path:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-strict-exactly-once \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --stream wrecking_ball
```

JetStream concurrent exactly-once queue path:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-concurrent-exactly-once \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --stream wrecking_ball
```

JetStream concurrent queue with a larger in-flight cap:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-concurrent \
  --consumers 3 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --js-max-ack-pending 100000
```

JetStream concurrent queue with separate server and client windows:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-concurrent \
  --consumers 5 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --js-max-ack-pending 1000000 \
  --js-pull-batch 5000
```

JetStream concurrent queue with a clean reset of prior JetStream state:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-concurrent \
  --recreate \
  --consumers 5 \
  --producer-rate 100000 \
  --producer-duration 30s
```

Consumer throttled slower than producer:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode js-queue-concurrent \
  --consumers 3 \
  --producer-rate 100000 \
  --consumer-rate 10000 \
  --producer-duration 30s \
  --drain-ms 10000
```

Processing delay:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --consumers 2 \
  --producer-rate 10000 \
  --processing-delay 50ms \
  --producer-duration 30s
```

Larger randomized payloads:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --consumers 2 \
  --producer-rate 100000 \
  --avg-payload-bytes 65536 \
  --producer-duration 30s
```

Monitor a specific local NATS server PID:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --consumers 2 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --nats-pid 12345
```

Disable local `nats-server` auto-detection:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode fanout \
  --consumers 2 \
  --producer-rate 100000 \
  --producer-duration 30s \
  --auto-monitor-nats=false
```

Custom req-reply queue group:

```bash
cargo run --bin nats-wrecking-ball -- \
  --profile generic \
  --mode req-reply \
  --consumers 2 \
  --queue-group wrecking_ball \
  --producer-rate 10000 \
  --producer-duration 30s
```

## Standalone producer

Fanout:

```bash
cargo run --bin nats-wrecking-ball-producer -- \
  --profile generic \
  --mode fanout \
  --rate 100000 \
  --duration 30s
```

Req-reply:

```bash
cargo run --bin nats-wrecking-ball-producer -- \
  --profile generic \
  --mode req-reply \
  --rate 10000 \
  --duration 30s
```

JetStream queue:

```bash
cargo run --bin nats-wrecking-ball-producer -- \
  --profile generic \
  --mode js-queue-concurrent \
  --rate 100000 \
  --duration 30s \
  --stream wrecking_ball
```

JetStream strict exactly-once:

```bash
cargo run --bin nats-wrecking-ball-producer -- \
  --profile generic \
  --mode js-queue-strict-exactly-once \
  --rate 100000 \
  --duration 30s \
  --stream wrecking_ball
```

JetStream concurrent exactly-once:

```bash
cargo run --bin nats-wrecking-ball-producer -- \
  --profile generic \
  --mode js-queue-concurrent-exactly-once \
  --rate 100000 \
  --duration 30s \
  --stream wrecking_ball
```

## Standalone consumer

Fanout:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode fanout
```

Fanout with rate cap and delay:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode fanout \
  --rate 10000 \
  --processing-delay 50ms
```

Request/reply responder:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode req-reply
```

Queue worker:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode queue
```

JetStream queue strict worker:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode js-queue-strict \
  --stream wrecking_ball \
  --consumer wrecking_ball_workers
```

JetStream queue concurrent worker:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode js-queue-concurrent \
  --stream wrecking_ball \
  --consumer wrecking_ball_workers
```

JetStream replay worker:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode js-replay \
  --stream wrecking_ball \
  --consumer wrecking_ball_replay
```

JetStream strict exactly-once worker:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode js-queue-strict-exactly-once \
  --stream wrecking_ball \
  --consumer wrecking_ball_workers
```

JetStream concurrent exactly-once worker:

```bash
cargo run --bin nats-wrecking-ball-consumer -- \
  --profile generic \
  --mode js-queue-concurrent-exactly-once \
  --stream wrecking_ball \
  --consumer wrecking_ball_workers
```

## Common knobs

- `--producer-rate` / `--consumer-rate`: messages per second. Omit for
  unlimited.
- `--mode fanout`: core NATS publish/subscribe with full fanout to all
  consumers.
- `--mode queue`: core NATS queue group with one consumer in the group handling
  each message.
- `--mode req-reply`: core NATS request/reply with a shared responder queue
  group. `--queue-group` optionally overrides the default `wrecking_ball`
  group.
- `--mode js-queue-strict`: JetStream durable work queue with one unacked
  message allowed in flight.
- `--mode js-queue-concurrent`: JetStream durable work queue with multiple
  in-flight messages allowed.
- `--mode js-queue-strict-exactly-once`: strict JetStream queue plus publish
  dedup IDs and confirmed consumer acks.
- `--mode js-queue-concurrent-exactly-once`: concurrent JetStream queue plus
  publish dedup IDs and confirmed consumer acks.
- `--mode js-replay`: JetStream retained-stream replay mode. Each consumer
  instance gets its own durable replay cursor.
- `--producers` / `--consumers`: number of separate producer and consumer
  instances the orchestrator starts.
- `--profile generic`: plain local NATS on `nats://127.0.0.1:4222`.
- `--profile gap3`: repo-local TLS defaults for the `gap3-rivendell` NATS
  instance.
- `--producer-count` / `--consumer-count`: stop after this many messages.
- `--producer-duration` / `--consumer-duration`: stop after this duration.
- `--recreate`: reset the effective mode state before the run. For JetStream
  modes this deletes the effective stream first, which also drops the
  associated durable consumers. For Core NATS modes this is a no-op because
  there is no server-side queue object to recreate.
- `--avg-payload-bytes`: average randomized payload size. Default `1024`.
- `--processing-delay`: add per-message handling delay on consumers.
- `--drain-ms`: extra time to let consumers drain after the producer stops.
- `--jetstream-ack-mode`: `ack`, `confirmed`, or `none` for JetStream modes.
  The exactly-once queue modes force confirmed acking.
- `--jetstream-max-ack-pending` / `--js-max-ack-pending`: override the
  JetStream consumer in-flight cap. Defaults are mode-based: `1` for strict,
  `1000` for concurrent and replay.
- `--jetstream-pull-batch` / `--js-pull-batch`: override the client-side pull
  batch size. Defaults are mode-based: `1` for strict, `200` for concurrent and
  replay.
- default JetStream names are mode-specific. If you leave `--stream` at
  `wrecking_ball` and `--consumer` at `wrecking_ball_workers`, the tool derives
  distinct names per JetStream mode to avoid stale-state collisions. Explicit
  overrides are used as-is.
- default Core names are mode-specific too. If you leave `--subject` at
  `test.nats_wrecking_ball`, the tool derives a distinct subject per mode,
  and `queue` / `req-reply` derive distinct default queue-group names unless
  you override them explicitly.
- `--nats-pid`: monitor a specific local `nats-server` PID.
- `--auto-monitor-nats=false`: disable local `nats-server` auto-detection.
- `--resource-sample-ms`: CPU and RSS sampling interval in milliseconds.
- `--server`, `--tls`, `--ca-cert`, `--client-cert`, `--client-key`: override
  the selected profile when needed.
