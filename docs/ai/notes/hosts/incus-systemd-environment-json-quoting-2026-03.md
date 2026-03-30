# Incus Systemd Environment JSON Quoting

## Context

The shared `lib/incus/default.nix` module passes several structured helper
inputs through systemd `Environment=` assignments:

- declared images / instances
- per-machine image spec
- desired disk spec
- disk GC metadata
- create-only device spec
- user metadata
- instance config

These values were rendered as raw JSON without quoting the full assignment.

## Problem

systemd parses `Environment=` using shell-like quoting rules. Raw JSON such as:

`INCUS_MACHINES_DESIRED_DISKS={"state":{"path":"/var/lib","type":"disk"}}`

arrives in the service environment with the inner double quotes stripped, which
turns it into invalid pseudo-JSON:

`{state:{path:/var/lib,type:disk}}`

The Incus helper then emits `jq: parse error` and silently loses structured
reconcile inputs. That can mask drift:

- create-only devices such as `gpu` / `unix-char` are not applied on create
- disk GC metadata sync is skipped
- image / GC / reconciler helpers do not reliably consume their declared JSON

## Decision

Use a shared helper:

- `mkEnvAssignment = name: value: "${name}=${lib.escapeShellArg (toString value)}";`

and apply it to all `lib/incus/default.nix` systemd environment assignments,
including scalar values for consistency.

## Result

systemd now preserves the JSON payloads exactly, so the helper receives valid
JSON and the structured reconcile logic can fail or act on real input instead of
degraded strings.
