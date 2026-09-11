# pvl-x2 Ollama Model Refresh, 2026-09

## Incident

A dirty-staged `pvl-x2` deployment on 2026-09-11 changed the required Ollama
models from `qwen3.6:27b` to `qwen3.8:27b` and added `ornith-1.5:{9b,35b}`. The
deployment and post-deploy health check succeeded, but the live Ollama inventory
did not change.

The deployed generation was correct. Its rendered `pvl-ollama-models.service`
contained the new model arguments, and its `X-Restart-Triggers` store path and
required-model hash differed from the snapshot generation. Activation reloaded
the `pvl` user manager at 11:20:33, but selected only `nixos-activation.service`
for restart. The model-puller had no journal entries during the deployment
window.

Live state after deployment showed:

- `pvl-ollama-models.service` was `inactive/dead`, with its last successful run
  at 2026-09-09 03:30:13 after boot;
- `pvl-ollama-models-boot.timer` was `active/elapsed`, with the same last
  trigger and no next trigger;
- Ollama still had `qwen3.6:27b` and `ornith:{9b,35b}`, and did not have the
  three newly required tags.

## Root cause

NixOS `switch-to-configuration` compares changed user units only from the user
manager's active or activating unit set. `restartTriggers` changes the rendered
unit comparison, but does not independently start an inactive static unit.

The `pvl-x2` puller is `Type=oneshot` without `RemainAfterExit=true`. After the
boot timer's successful run, the service becomes inactive, so later model-list
changes are outside the switch comparison set. In contrast, the equivalent
`pvl-a1` and `pvl-l5` pullers set `RemainAfterExit=true`, leaving the completed
oneshot active so a changed restart trigger can rerun it during deployment.

This gap entered when the `pvl-x2` puller was simplified in `ed254745` after its
explicit `services.systemd-user-manager` ownership had been removed in
`293f4698`. The new native timer-based shape did not gain the retained-active
behavior already used by the other Pvl hosts.

## Health-check boundary

The successful health result was consistent with the current health contract.
Nixbot checks failed and transitional user units, declared managed user units,
and Podman runtime health. The inactive static model-puller is not a failed unit
and is not in the declared managed-unit set. The health check does not compare
`/api/tags` with the required-model declaration.

## Reconciliation semantics

Before this repair, the host-local puller was additive. Removing a model from
`requiredModels` does not delete it unless the unit also supplies it through
`OLLAMA_RETIRED_MODELS`. The original staged config would therefore have left
`qwen3.6:27b` installed even after fetching the three new tags.

## Durable fix and recovery boundary

- Add `RemainAfterExit = true` to the `pvl-x2` model-puller, matching `pvl-a1`,
  `pvl-l5`, and the shared `mkModelReconciler` dispatcher contract.
- Deploying that property alone will not start the currently inactive unit; the
  timer has already elapsed. Complete the first fixed rollout with an explicitly
  approved manual start, reboot, or bounded declarative one-time start so the
  oneshot enters and then retains the active state.
- If replacing `qwen3.6:27b` is intended to retire it, declare that retirement
  explicitly rather than treating absence from `requiredModels` as deletion.
- Starting `pvl-ollama-models.service` manually will reconcile the deployed
  required list immediately, but it performs large network pulls and persistent
  model-store mutation and therefore requires explicit live-operation approval.

## Repair and reconciliation

The staged repair:

- sets `RemainAfterExit = true`;
- defines `retiredModels = [ "qwen3.6:27b" ]` and exports the list as
  `OLLAMA_RETIRED_MODELS` from the generated pull wrapper;
- hashes both required and retired lists into the model-policy restart trigger;
- asserts that a model cannot be both required and retired.

The first repaired generation deployed successfully, but the approved one-time
start exposed a second, previously hidden blocker: Ollama `0.32.0` rejected the
`qwen3.8:27b` manifest with HTTP 412 because the model requires a newer Ollama.
The helper failed before either Ornith pull or retirement, preserving the old
inventory. `pvl-x2` was then moved to the current stable
`docker.io/ollama/ollama:0.33.3-rocm` image. This host-local version divergence
was required by its newer model policy at recovery time; a later cross-host
follow-up converged all Ollama images on `0.34.0`.

Nixbot pre-pulled the new image and deployed generation
`1zll0ydipgh2f7l86vwvvzgz61jx9r8b-nixos-system-pvl-x2-26.05.20260910.d58a46e`.
Live API and container inspection both reported Ollama `0.33.3`. The explicit
reconciliation then:

1. pulled `qwen3.8:27b`, `ornith-1.5:9b`, and `ornith-1.5:35b` successfully;
2. removed `qwen3.6:27b` only after every required pull had succeeded;
3. restarted the dependent `pvl-ollama.service`;
4. finished with `pvl-ollama-models.service` `active/exited`, result `success`,
   and exit status zero.

Final readback showed all three new tags, no `qwen3.6:27b`, no failed system or
user units, successful Ollama units, and matching current/profile generation
store paths. The retained-active state makes future policy-trigger changes
eligible for normal NixOS user-unit restart handling.

## Shared reconciler adoption

The final host definition delegates the model lifecycle to
`lib/services/ollama.mkModelReconciler`. Deployment generation 14 replaced the
host-local puller and timer with the shared retained dispatcher and asynchronous
worker. Live verification showed the dispatcher `active/exited`, the worker
`inactive/dead` with result `success`, no legacy timer, and matching
current/profile generation paths.

The shared module was subsequently extended with explicit backend-service
ordering. `pvl-x2` declares `pvl-ollama.service`, allowing the helper to
discover and `try-restart` the backend after future model-store changes. That
follow-up was built together with the `pvl-a1` and `pvl-l5` migrations and the
fleet-wide Ollama `0.34.0` bump, but was not deployed during this task.
