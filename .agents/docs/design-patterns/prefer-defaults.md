# Prefer Upstream Defaults

Stick to upstream/framework defaults as much as possible for things like systemd
behavior, container runtime policies, and similar infrastructure knobs.

## Why

- Keeps the mental model simple — anyone familiar with the tool already knows
  what to expect.
- Avoids creating a repo-specific paradigm that has to be learned, documented,
  and maintained.
- Default behaviors are the most tested and best documented paths.

## When to Override

Only override a default when there is a concrete, demonstrated need — not
speculatively. If an override is added, it should be obvious why the default was
insufficient.

## Examples

- **systemd restart policy**: use `Restart=on-failure` without custom
  `RestartSec`, `StartLimitBurst`, or `StartLimitIntervalSec` — systemd's
  built-in defaults (5 bursts in 10 seconds) already provide reasonable
  failure-limiting behavior.
- **Container restart policies**: prefer the compose-level default rather than
  adding custom restart directives unless the service has specific requirements.
